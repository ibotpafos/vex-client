using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

// One Wintun owner and one AWG engine. This path never starts the vendor
// service alongside NetTUN. Signature admission remains in the named-pipe
// server; routing signatures are independently checked inside the pinned Go
// engine. No caller-supplied paths, interface indices or destination exceptions.
public sealed class RoutedAwgTunnelRuntime : IVpnTunnelRuntime, IVpnRuntimeLifetime, IDisposable
{
    private readonly WindowsServiceOptions _options;
    private readonly NetworkSafetyController _safety;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly VpnRuntimeBackgroundWork _background = new();
    private readonly string _private, _parameters, _lease, _policyCache;
    private Process? _engine;
    private RoutedEngineJob? _job;
    private VpnAuthorizedProfile? _profile;
    private bool _antiLeak, _transportStopped, _suspended;
    private PhysicalInterface? _physical;
    private DateTimeOffset _cacheCheck;

    public RoutedAwgTunnelRuntime(WindowsServiceOptions options) {
        _options = options;
        // Control recovery is carried by the engine's hostname identity, so
        // real CDN IPs must not become system bypass routes/HTTPS allowances.
        _safety = new NetworkSafetyController(options with { ControlPlaneBypassHosts = [] });
        _private = Path.Combine(options.DataDirectory, "Private");
        _parameters = Path.Combine(_private, "routing-parameters.json");
        _lease = Path.Combine(_private, "routed-lease.json");
        _policyCache = Path.Combine(_private, "routing-policy.json");
        EnsurePrivateDirectory();
        VerifyAssets();
        _background.Run(WatchAsync);
    }

    public Task<VpnTunnelStatus> ConnectAsync(string locationId, string tunnelConfig, DateTimeOffset? authorizationExpiresAt, CancellationToken cancellationToken) =>
        throw new VpnTunnelException("trusted_profile_required");

    public async Task<VpnTunnelStatus> ConnectAuthorizedAsync(VpnAuthorizedProfile profile, bool antiLeakEnabled, CancellationToken cancellationToken) {
        VpnTunnelConfigurationValidator.Validate(profile.TunnelConfig);
        if (profile.ExpiresAt <= DateTimeOffset.UtcNow || profile.Addresses.Count == 0 || profile.Dns.Count == 0) { throw new VpnTunnelException("profile_expired"); }
        var mode = profile.RoutingMode switch {
            "split" or "all_except_ru" => "all_except_ru", "full" or "full_tunnel" => "full_tunnel",
            _ => throw new VpnTunnelException("profile_routing_invalid"),
        };
        if (mode == "all_except_ru" && profile.BypassRegion != "ru") { throw new VpnTunnelException("profile_routing_invalid"); }
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var replacing = false;
        try {
            VerifyAssets();
            var physical = await ReadPhysicalAsync(cancellationToken).ConfigureAwait(false);
            // Admission before replacement: old capture/filters remain until
            // the next signed interface metadata has passed Go admission.
            var nextParameters = Parameters(profile, physical.Index, mode);
            Atomic(_parameters + ".pending", nextParameters);
            await RunEngineControlAsync(["--check-routing-parameters", "--parameters", _parameters + ".pending", "vex"], cancellationToken).ConfigureAwait(false);
            if (_engine?.HasExited == false && !_transportStopped && _profile?.TunnelConfig == profile.TunnelConfig &&
                _profile.RoutingMode == profile.RoutingMode && _profile.LocationId == profile.LocationId) {
                _profile = profile;
                Atomic(_lease, JsonSerializer.Serialize(new Lease(profile, antiLeakEnabled)));
                if (_antiLeak != antiLeakEnabled) {
                    _antiLeak = antiLeakEnabled;
                    if (_antiLeak) { await ArmAsync(cancellationToken).ConfigureAwait(false); } else { await _safety.DisarmFirewallOnlyAsync(cancellationToken).ConfigureAwait(false); }
                }
                return await StatusCoreAsync(cancellationToken).ConfigureAwait(false);
            }
            replacing = true;
            await StopEngineAsync().ConfigureAwait(false);
            await CleanupInterfaceAsync(CancellationToken.None).ConfigureAwait(false);
            await StopOwnedVendorAsync(cancellationToken).ConfigureAwait(false);
            Atomic(_parameters, nextParameters);
            _profile = profile; _antiLeak = antiLeakEnabled; _physical = physical; _transportStopped = false; _suspended = false;
            // A durable intent precedes the child process. A service crash
            // kills that child through its Job; the default Block survives.
            Atomic(_lease, JsonSerializer.Serialize(new Lease(profile, antiLeakEnabled)));
            await _safety.ApplyControlPlaneBypassAsync(Endpoint, cancellationToken, PublicKey, profile.ExpiresAt).ConfigureAwait(false);
            if (antiLeakEnabled) { await ArmAsync(cancellationToken).ConfigureAwait(false); }
            else { await _safety.DisarmFirewallOnlyAsync(cancellationToken).ConfigureAwait(false); }
            StartEngine();
            var adapter = await WaitAdapterAsync(cancellationToken).ConfigureAwait(false);
            await ConfigureInterfaceAsync(adapter, profile, cancellationToken).ConfigureAwait(false);
            // Route/DNS capture is installed before the peer is activated.
            var literalEndpoint = await LiteralEndpointAsync(Endpoint, cancellationToken).ConfigureAwait(false);
            await SetConfigurationAsync(VpnUapiConfigurationRenderer.Render(profile.TunnelConfig, literalEndpoint), cancellationToken).ConfigureAwait(false);
            return await StatusCoreAsync(cancellationToken).ConfigureAwait(false);
        } catch {
            // Keep requested protection after failed admission/handshake/start.
            // Only an explicit disconnect restores the original firewall state.
            if (replacing && _engine is not null && !_engine.HasExited) { try { await StopTransportAsync(CancellationToken.None).ConfigureAwait(false); } catch { await StopEngineAsync().ConfigureAwait(false); } }
            throw;
        } finally { try { File.Delete(_parameters + ".pending"); } catch (IOException) { } _gate.Release(); }
    }

    public async Task<VpnTunnelStatus> GetStatusAsync(CancellationToken cancellationToken) {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await StatusCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    public Task<VpnTunnelStatus> GetDiagnosticsAsync(CancellationToken cancellationToken) => GetStatusAsync(cancellationToken);

    private async Task<VpnTunnelStatus> StatusCoreAsync(CancellationToken token) {
        if (_profile is null) {
            if (File.Exists(_lease)) {
                // Never release durable protection merely because the service
                // or its child exited. Reconnect must re-admit a signed profile.
                return new VpnTunnelStatus(VpnConnectionPhase.Error, null, "routing_reconnect_required", _safety.Capture(null, null, true));
            }
            return VpnTunnelStatus.Disconnected();
        }
        if (_engine is null || _engine.HasExited) { return new VpnTunnelStatus(VpnConnectionPhase.Error, _profile.LocationId, "routing_engine_stopped", _safety.Capture(null, Endpoint, true)); }
        if (_profile.ExpiresAt <= DateTimeOffset.UtcNow && !_transportStopped) { await StopTransportAsync(token).ConfigureAwait(false); }
        var physical = await ReadPhysicalAsync(token).ConfigureAwait(false);
        if (_physical != physical) {
            // Narrow owned firewall scope first; stale protected sockets are
            // closed by the engine before it reopens the AWG bind.
            _physical = physical;
            if (_antiLeak) { await ArmAsync(token).ConfigureAwait(false); }
            await RunEngineControlAsync(["--update-underlay", "--physical-interface-index", physical.Index.ToString(), "vex"], token).ConfigureAwait(false);
            await _safety.ApplyControlPlaneBypassAsync(Endpoint, token, PublicKey, _profile.ExpiresAt).ConfigureAwait(false);
        }
        var adapter = FindAdapter();
        var diagnostics = _safety.Capture(adapter, Endpoint, true, ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"], _profile.Dns, PublicKey);
        if (!_transportStopped) {
            try {
                var peer = await AmneziaPeerStatusClient.ReadAsync(PublicKey, token).ConfigureAwait(false);
                diagnostics = diagnostics with { RxBytes = peer.RxBytes, TxBytes = peer.TxBytes, LatestHandshakeAt = peer.LatestHandshakeAt,
                    Findings = diagnostics.Findings.Concat(peer.LatestHandshakeAt is null ? new[] { "handshake_pending" } : DateTimeOffset.UtcNow - peer.LatestHandshakeAt > TimeSpan.FromSeconds(180) ? new[] { "handshake_stale" } : []).ToArray() };
            } catch (VpnTunnelException error) { diagnostics = diagnostics with { Findings = diagnostics.Findings.Append(error.Code).ToArray() }; }
        } else { diagnostics = diagnostics with { LeakProtection = _antiLeak ? VpnLeakProtectionState.Blocking : VpnLeakProtectionState.Off }; }
        if (DateTimeOffset.UtcNow >= _cacheCheck) {
            _cacheCheck = DateTimeOffset.UtcNow.AddMinutes(5);
            try { var authorization = await RunEngineControlAsync(["--get-routing-authorization", "vex"], token).ConfigureAwait(false); if (authorization.Length > 0 && authorization.Length <= 2 * 1024 * 1024) { Atomic(_policyCache, authorization); } } catch (VpnTunnelException) { }
        }
        if (_suspended) { return new VpnTunnelStatus(VpnConnectionPhase.Disconnected, null, null, diagnostics with { Findings = diagnostics.Findings.Append("routing_capture_retained").ToArray() }); }
        return new VpnTunnelStatus(_transportStopped ? VpnConnectionPhase.Error : VpnConnectionPhase.Connected, _profile.LocationId,
            _transportStopped ? "profile_expired" : null, diagnostics);
    }

    public async Task<VpnTunnelStatus> SetAntiLeakAsync(bool enabled, CancellationToken cancellationToken) {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { _antiLeak = enabled; if (enabled && _profile is not null) { await ArmAsync(cancellationToken).ConfigureAwait(false); } else if (!enabled) { await _safety.DisarmFirewallOnlyAsync(cancellationToken).ConfigureAwait(false); } return await StatusCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    public async Task<VpnTunnelStatus> DisconnectAsync(CancellationToken cancellationToken) {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try {
            await StopEngineAsync().ConfigureAwait(false);
            await CleanupInterfaceAsync(cancellationToken).ConfigureAwait(false);
            await _safety.RollbackAsync(cancellationToken).ConfigureAwait(false);
            File.Delete(_lease); File.Delete(_parameters); _profile = null;
            return VpnTunnelStatus.Disconnected();
        } finally { _gate.Release(); }
    }

    public async Task<VpnTunnelStatus> SuspendAsync(CancellationToken cancellationToken) {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try {
            if (_engine is null || _engine.HasExited) { return new VpnTunnelStatus(VpnConnectionPhase.Disconnected, null, null, _safety.Capture(null, null, true)); }
            await StopTransportAsync(cancellationToken).ConfigureAwait(false); _suspended = true;
            return await StatusCoreAsync(cancellationToken).ConfigureAwait(false);
        } finally { _gate.Release(); }
    }

    private async Task ArmAsync(CancellationToken token) {
        var physical = _physical ?? throw new VpnTunnelException("routing_underlay_missing");
        await _safety.ArmFirewallAsync("vex", Endpoint, token, PublicKey, _profile?.ExpiresAt, new RoutedFirewallScope(Executable, physical.Name)).ConfigureAwait(false);
    }

    private async Task StopTransportAsync(CancellationToken token) {
        await RunEngineControlAsync(["--stop-transport", "vex"], token).ConfigureAwait(false); _transportStopped = true;
    }

    private void StartEngine() {
        var info = new ProcessStartInfo(Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = _options.InstallDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var value in new[] { "-f", "--parameters", _parameters, "vex" }) { info.ArgumentList.Add(value); }
        _engine = Process.Start(info) ?? throw new VpnTunnelException("routing_engine_launch_failed");
        _job = new RoutedEngineJob(); _job.Attach(_engine);
        // Drain generic native logs without emitting key material into owner logs.
        _ = _engine.StandardOutput.ReadToEndAsync(); _ = _engine.StandardError.ReadToEndAsync();
    }

    private async Task StopEngineAsync() {
        if (_engine is null) { return; }
        if (!_engine.HasExited) { _engine.Kill(entireProcessTree: true); using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await _engine.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        _engine.Dispose(); _engine = null; _job?.Dispose(); _job = null;
    }

    private async Task<string> RunEngineControlAsync(IReadOnlyList<string> args, CancellationToken token) {
        var info = new ProcessStartInfo(Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = _options.InstallDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var value in args) { info.ArgumentList.Add(value); }
        using var process = Process.Start(info) ?? throw new VpnTunnelException("routing_control_failed");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false); } throw; }
        _ = await error.ConfigureAwait(false); var result = await output.ConfigureAwait(false);
        if (process.ExitCode != 0 || result.Length > 2 * 1024 * 1024) { throw new VpnTunnelException("routing_control_failed"); }
        return result.Trim();
    }

    private static async Task SetConfigurationAsync(string configuration, CancellationToken token) {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        await using var pipe = new NamedPipeClientStream(".", @"ProtectedPrefix\Administrators\AmneziaWG\vex", PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
        await pipe.WriteAsync(Encoding.UTF8.GetBytes("set=1\n" + configuration.TrimEnd() + "\n\n"), timeout.Token).ConfigureAwait(false);
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
        if (await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false) != "errno=0") { throw new VpnTunnelException("routing_configuration_failed"); }
    }

    private async Task StopOwnedVendorAsync(CancellationToken token) {
        if (!OwnedVendorServiceRegistration.QualifyIfPresent(Path.Combine(_options.InstallDirectory, "amneziawg.exe"), Path.Combine(_private, "vex.conf"))) { return; }
        using var service = new ServiceController(WindowsServiceOptions.VendorServiceName); service.Refresh();
        if (service.Status == ServiceControllerStatus.Stopped) { return; }
        if (service.Status != ServiceControllerStatus.StopPending) { service.Stop(); }
        var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
        while (service.Status != ServiceControllerStatus.Stopped) { if (DateTimeOffset.UtcNow >= deadline) { throw new VpnTunnelException("routing_vendor_stop_unconfirmed"); } await Task.Delay(100, token).ConfigureAwait(false); service.Refresh(); }
    }

    private string Parameters(VpnAuthorizedProfile profile, int index, string mode) {
        JsonElement? previous = null;
        if (new FileInfo(_policyCache) is { Exists: true, Length: <= 2 * 1024 * 1024 }) { try { previous = JsonSerializer.Deserialize<JsonElement>(File.ReadAllBytes(_policyCache)); } catch (JsonException) { } }
        return JsonSerializer.Serialize(new { routing = new { addresses = profile.Addresses, dns = profile.Dns, mode, authorization = mode == "all_except_ru" ? previous : null, previous_authorization = previous }, physical_interface_index = index }, new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull });
    }

    private string Executable => Path.Combine(_options.InstallDirectory, "vex-awg.exe");
    private string Endpoint => ConfigValue(_profile!.TunnelConfig, "Endpoint");
    private string PublicKey => ConfigValue(_profile!.TunnelConfig, "PublicKey");
    private static string ConfigValue(string config, string name) => config.Split('\n').Select(line => line.Split('=', 2)).First(parts => parts.Length == 2 && parts[0].Trim().Equals(name, StringComparison.OrdinalIgnoreCase))[1].Trim();

    private void VerifyAssets() {
        if (!VpnRoutingCapability.IsAvailable(_options.DataDirectory)) { throw new VpnTunnelException("routing_runtime_untrusted"); }
        foreach (var value in new[] { (Executable, Path.Combine(_options.DataDirectory, "router-sha256")), (Path.Combine(_options.InstallDirectory, "wintun.dll"), _options.WintunSha256File) }) {
            using var stream = File.OpenRead(value.Item1);
            if (!string.Equals(Convert.ToHexString(SHA256.HashData(stream)), File.ReadAllText(value.Item2).Trim(), StringComparison.OrdinalIgnoreCase)) { throw new VpnTunnelException("routing_runtime_untrusted"); }
        }
        // Authenticode extraction has no replacement loader for signed PE files.
#pragma warning disable SYSLIB0057
        using var certificate = X509Certificate.CreateFromSignedFile(Executable);
#pragma warning restore SYSLIB0057
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(certificate.GetRawCertData())), File.ReadAllText(_options.ClientCertificateSha256File).Trim(), StringComparison.OrdinalIgnoreCase)) { throw new VpnTunnelException("routing_runtime_untrusted"); }
    }

    private void EnsurePrivateDirectory() {
        Directory.CreateDirectory(_private);
        if (new DirectoryInfo(_private).Attributes.HasFlag(FileAttributes.ReparsePoint)) { throw new VpnTunnelException("routing_state_untrusted"); }
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid }) { security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(_private), security);
    }

    private static void Atomic(string path, string value) { var temporary = path + ".pending-write"; File.WriteAllText(temporary, value, new UTF8Encoding(false)); File.Move(temporary, path, overwrite: true); }

    private static async Task<PhysicalInterface> ReadPhysicalAsync(CancellationToken token) {
        const string script = """
            $ErrorActionPreference='Stop'
            $physical=@(Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up'})
            $route=Get-NetRoute -PolicyStore ActiveStore | Where-Object {$_.DestinationPrefix -in @('0.0.0.0/0','::/0') -and $_.InterfaceIndex -in @($physical.ifIndex)} | Sort-Object RouteMetric | Select-Object -First 1
            if(!$route){throw 'routing_physical_missing'}
            $adapter=$physical | Where-Object {$_.ifIndex -eq $route.InterfaceIndex} | Select-Object -First 1
            @{Index=[int]$adapter.ifIndex;Name=$adapter.Name} | ConvertTo-Json -Compress
            """;
        return JsonSerializer.Deserialize<PhysicalInterface>(await NetworkSafetyController.RunPowerShellAsync(script, [], token).ConfigureAwait(false)) ?? throw new VpnTunnelException("routing_underlay_missing");
    }

    private static NetworkInterface? FindAdapter() => NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(adapter => adapter.Name == "vex");
    private async Task<NetworkInterface> WaitAdapterAsync(CancellationToken token) {
        for (var i = 0; i < 40; i++) { if (_engine?.HasExited != false) { throw new VpnTunnelException("routing_engine_stopped"); } if (FindAdapter() is { } adapter) { return adapter; } await Task.Delay(100, token).ConfigureAwait(false); }
        throw new VpnTunnelException("routing_adapter_missing");
    }

    private string InterfaceJournal => Path.Combine(_private, "routed-interface.json");
    private async Task ConfigureInterfaceAsync(NetworkInterface adapter, VpnAuthorizedProfile profile, CancellationToken token) {
        var index = adapter.GetIPProperties().GetIPv4Properties()?.Index ?? adapter.GetIPProperties().GetIPv6Properties()?.Index ?? throw new VpnTunnelException("routing_adapter_missing");
        var addresses = profile.Addresses.ToList(); if (!addresses.Any(value => value.Contains(':'))) { addresses.Add("fd7a:115c:a1e0:ffff::1/120"); }
        // The baseline/ownership plan is durable before applying addresses,
        // DNS or four capture routes. Existing unowned state is rejected.
        const string capture = """
            $ErrorActionPreference='Stop';$index=[int]$args[0]
            $adapter=Get-NetAdapter -IncludeHidden | Where-Object {$_.ifIndex -eq $index}
            if($adapter.Name -cne 'vex'){throw 'routing_adapter_untrusted'}
            $addresses=@(Get-NetIPAddress -InterfaceIndex $index | Where-Object {$_.IPAddress -notlike 'fe80:*'})
            if($addresses.Count -gt 0){throw 'routing_adapter_address_conflict'}
            $routes=@('0.0.0.0/1','128.0.0.0/1','::/1','8000::/1')
            if(@(Get-NetRoute -InterfaceIndex $index -PolicyStore ActiveStore | Where-Object {$_.DestinationPrefix -in $routes}).Count -gt 0){throw 'routing_capture_conflict'}
            @{Index=$index;AdapterId=$adapter.InterfaceGuid.ToString();Dns=@((Get-DnsClientServerAddress -InterfaceIndex $index).ServerAddresses);Addresses=@(ConvertFrom-Json $args[1]);Routes=$routes} | ConvertTo-Json -Compress -Depth 4
            """;
        var journal = await NetworkSafetyController.RunPowerShellAsync(capture, [index.ToString(), JsonSerializer.Serialize(addresses)], token).ConfigureAwait(false); Atomic(InterfaceJournal, journal);
        const string apply = """
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0];$adapter=Get-NetAdapter -IncludeHidden | Where-Object {$_.ifIndex -eq $state.Index}
            if($adapter.InterfaceGuid.ToString() -ine $state.AdapterId -or $adapter.Name -cne 'vex'){throw 'routing_adapter_changed'}
            foreach($address in @($state.Addresses)){$parts=$address.Split('/');New-NetIPAddress -InterfaceIndex $state.Index -IPAddress $parts[0] -PrefixLength ([int]$parts[1]) -PolicyStore ActiveStore | Out-Null}
            Set-NetIPInterface -InterfaceIndex $state.Index -NlMtuBytes 1360 -InterfaceMetric 5 -PolicyStore ActiveStore
            Set-DnsClientServerAddress -InterfaceIndex $state.Index -ServerAddresses @(ConvertFrom-Json $args[1])
            foreach($prefix in @($state.Routes)){$gateway=if($prefix.Contains(':')){'::'}else{'0.0.0.0'};New-NetRoute -InterfaceIndex $state.Index -DestinationPrefix $prefix -NextHop $gateway -RouteMetric 0 -PolicyStore ActiveStore | Out-Null}
            'ok'
            """;
        await NetworkSafetyController.RunPowerShellAsync(apply, [journal, JsonSerializer.Serialize(profile.Dns)], token).ConfigureAwait(false);
    }

    private async Task CleanupInterfaceAsync(CancellationToken token) {
        if (!File.Exists(InterfaceJournal)) { return; }
        const string script = """
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0];$adapter=Get-NetAdapter -IncludeHidden | Where-Object {$_.ifIndex -eq $state.Index} -ErrorAction SilentlyContinue
            if($adapter){
                if($adapter.InterfaceGuid.ToString() -ine $state.AdapterId -or $adapter.Name -cne 'vex'){throw 'routing_cleanup_owner_changed'}
                foreach($prefix in @($state.Routes)){Get-NetRoute -InterfaceIndex $state.Index -DestinationPrefix $prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.RouteMetric -eq 0 -and $_.NextHop -in @('0.0.0.0','::')} | Remove-NetRoute -Confirm:$false}
                foreach($address in @($state.Addresses)){$parts=$address.Split('/');Get-NetIPAddress -InterfaceIndex $state.Index -IPAddress $parts[0] -ErrorAction SilentlyContinue | Where-Object {$_.PrefixLength -eq [int]$parts[1]} | Remove-NetIPAddress -Confirm:$false}
                if(@($state.Dns).Count){Set-DnsClientServerAddress -InterfaceIndex $state.Index -ServerAddresses @($state.Dns)}else{Set-DnsClientServerAddress -InterfaceIndex $state.Index -ResetServerAddresses}
            }
            'ok'
            """;
        await NetworkSafetyController.RunPowerShellAsync(script, [File.ReadAllText(InterfaceJournal)], token).ConfigureAwait(false); File.Delete(InterfaceJournal);
    }

    private static async Task<string> LiteralEndpointAsync(string endpoint, CancellationToken token) {
        var uri = new Uri("udp://" + endpoint); var host = uri.Host.Trim('[', ']');
        var address = IPAddress.TryParse(host, out var literal) ? literal : (await Dns.GetHostAddressesAsync(host, token).ConfigureAwait(false)).FirstOrDefault() ?? throw new VpnTunnelException("routing_endpoint_unavailable");
        return address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? $"[{address}]:{uri.Port}" : $"{address}:{uri.Port}";
    }

    private async Task WatchAsync(CancellationToken token) {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false)) { try { await GetStatusAsync(token).ConfigureAwait(false); } catch (Exception error) when (error is VpnTunnelException or IOException or Win32Exception) { /* Protection remains durable; no fail-open rollback. */ } }
    }

    public void BeginShutdown() => _background.Stop();
    public async Task QuiesceAsync(CancellationToken token) { _background.Stop(); await _background.DrainAsync(token).ConfigureAwait(false); await _gate.WaitAsync(token).ConfigureAwait(false); try { await StopEngineAsync().ConfigureAwait(false); } finally { _gate.Release(); } }
    public void Dispose() { _background.Stop(); _job?.Dispose(); _engine?.Dispose(); }
    private sealed record PhysicalInterface(int Index, string Name);
    private sealed record Lease(VpnAuthorizedProfile Profile, bool AntiLeak);
}

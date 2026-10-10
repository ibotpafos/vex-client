using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

internal sealed class NetworkSafetyController
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan FirewallVerificationLifetime = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DnsResolutionTimeout = TimeSpan.FromSeconds(4);
    private readonly IReadOnlyList<string> _controlPlaneHosts;
    private readonly HashSet<IPAddress> _nativeLocalEndpointAddresses;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly string _firewallStatePath;
    private readonly string _routeStatePath;
    private readonly string _endpointAddressCachePath;
    private readonly string _controlPlaneAddressCachePath;
    private readonly string _routeReceiptsDirectory;
    private readonly Func<string, IReadOnlyList<string>, CancellationToken, Task<string>> _commandRunner;
    private readonly Func<string, CancellationToken, Task<IPAddress[]>> _dnsResolver;
    private readonly VpnEndpointAddressCache _endpointAddressCache = new();
    private readonly VpnControlPlaneAddressCache _controlPlaneAddressCache = new();
    private IReadOnlyDictionary<IPAddress, RouteCommandResult> _expectedBypassRoutes =
        new Dictionary<IPAddress, RouteCommandResult>();
    private IReadOnlyList<BypassRoute> _activeBypassRoutes = [];
    private bool _firewallArmed;
    private bool _firewallVerified;
    private DateTimeOffset _firewallVerifiedAt;
    private int _verificationPending;
    private bool _routeJournalUnverified;
    public NetworkSafetyController(WindowsServiceOptions options,
        Func<string, IReadOnlyList<string>, CancellationToken, Task<string>>? commandRunner = null,
        Func<string, CancellationToken, Task<IPAddress[]>>? dnsResolver = null)
    {
        _controlPlaneHosts = options.ControlPlaneBypassHosts.ToArray();
        _nativeLocalEndpointAddresses = options.NativeLocalEndpointAddresses.Select(IPAddress.Parse).ToHashSet();
        _firewallStatePath = Path.Combine(options.DataDirectory, "firewall-rollback.json");
        _routeStatePath = Path.Combine(options.DataDirectory, "bypass-routes.json");
        _endpointAddressCachePath = Path.Combine(options.DataDirectory, "endpoint-address-cache.json");
        _controlPlaneAddressCachePath = Path.Combine(options.DataDirectory, "control-plane-address-cache.json");
        _routeReceiptsDirectory = Path.Combine(options.DataDirectory, "bypass-route-confirmations");
        _commandRunner = commandRunner ?? RunPowerShellAsync;
        _dnsResolver = dnsResolver ?? ((host, token) => Dns.GetHostAddressesAsync(host, token));
        // A journal indicates possible ownership, not proof that protection works.
        _firewallArmed = File.Exists(_firewallStatePath);
        _activeBypassRoutes = LoadPersistedRoutes();
        try
        {
            if (new FileInfo(_endpointAddressCachePath) is { Exists: true, Length: <= 16 * 1024 })
            {
                _endpointAddressCache.Restore(JsonSerializer.Deserialize<VpnEndpointAddressSnapshot>(
                    File.ReadAllText(_endpointAddressCachePath)), DateTimeOffset.UtcNow);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException)
        { /* Advisory routing metadata must not prevent service startup. */ }
        try
        {
            if (new FileInfo(_controlPlaneAddressCachePath) is { Exists: true, Length: <= 64 * 1024 })
            {
                _controlPlaneAddressCache.Restore(JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(
                    File.ReadAllText(_controlPlaneAddressCachePath)), _controlPlaneHosts, DateTimeOffset.UtcNow);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException)
        { /* Unscoped or expired routing metadata is advisory, never authority. */ }
    }

    public async Task ApplyControlPlaneBypassAsync(string endpoint, CancellationToken cancellationToken,
        string? serverPublicKey = null, DateTimeOffset? authorizationExpiresAt = null)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Repair the last admitted numeric peer before asking the tunnel's
            // currently broken DNS resolver to resolve its own endpoint.
            IReadOnlyList<IPAddress> cached = IPAddress.TryParse(ParseEndpointHost(endpoint), out var literal) ? [literal]
                : _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow);
            if (cached.Count > 0)
            {
                var control = CachedControlAddresses(endpoint, serverPublicKey, authorizationExpiresAt);
                var known = cached.Concat(control).Distinct().ToArray();
                await ReconcileBypassRoutesAsync(new ProtectedAddressSet(known, cached.ToArray(),
                    IPAddress.TryParse(ParseEndpointHost(endpoint), out _), ParseEndpointPort(endpoint),
                    control), cancellationToken).ConfigureAwait(false);
            }
            var resolved = await ResolveProtectedAddressesAsync(endpoint, cancellationToken, serverPublicKey, authorizationExpiresAt).ConfigureAwait(false);
            await ReconcileBypassRoutesAsync(resolved, cancellationToken).ConfigureAwait(false);
            if (_endpointAddressCache.RememberResolved(endpoint, serverPublicKey, resolved.EndpointAddresses,
                authorizationExpiresAt, DateTimeOffset.UtcNow)) { PersistEndpointAddressCache(); }
        }
        finally { _operationGate.Release(); }
    }

    public bool ObserveSelectedPeerEndpoint(string endpoint, string serverPublicKey,
        string? numericEndpoint, DateTimeOffset? authorizationExpiresAt)
    {
        var previous = _endpointAddressCache.Snapshot;
        if (!_endpointAddressCache.ObserveSelectedPeer(endpoint, serverPublicKey, numericEndpoint,
            authorizationExpiresAt, DateTimeOffset.UtcNow)) { return false; }
        var current = _endpointAddressCache.Snapshot!;
        if (previous is null || previous.Endpoint != current.Endpoint || previous.ServerPublicKey != current.ServerPublicKey ||
            previous.ValidUntil != current.ValidUntil || !previous.Addresses.SequenceEqual(current.Addresses)) { PersistEndpointAddressCache(); }
        var addresses = _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow);
        lock (_gate) { return addresses.Any(address => !_expectedBypassRoutes.ContainsKey(address)); }
    }

    public async Task EnsureKnownEndpointBypassAsync(string endpoint, string? serverPublicKey,
        CancellationToken cancellationToken, DateTimeOffset? authorizationExpiresAt = null)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var endpointAddresses = IPAddress.TryParse(ParseEndpointHost(endpoint), out var literal) ? [literal]
                : _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow).ToArray();
            if (endpointAddresses.Length == 0) { return; }
            lock (_gate)
            {
                if (endpointAddresses.Any(_expectedBypassRoutes.ContainsKey)) { return; }
            }
            // Cold service start or a newly authenticated numeric peer. Never
            // ask DNS from status capture, and do not wait for the watchdog.
            var control = CachedControlAddresses(endpoint, serverPublicKey, authorizationExpiresAt);
            await ReconcileBypassRoutesAsync(new ProtectedAddressSet(endpointAddresses.Concat(control).Distinct().ToArray(),
                endpointAddresses, literal is not null, ParseEndpointPort(endpoint), control), cancellationToken).ConfigureAwait(false);
        }
        finally { _operationGate.Release(); }
    }

    private void PersistEndpointAddressCache()
    {
        try { WriteAtomic(_endpointAddressCachePath, JsonSerializer.Serialize(_endpointAddressCache.Snapshot)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { /* Recovery can use the in-memory binding when advisory persistence fails. */ }
    }

    private IPAddress[] CachedControlAddresses(string endpoint, string? serverPublicKey, DateTimeOffset? expiresAt) =>
        _controlPlaneAddressCache.Get(endpoint, serverPublicKey, _controlPlaneHosts, expiresAt, DateTimeOffset.UtcNow)
            .Values.SelectMany(value => value).Distinct().ToArray();

    private void PersistControlPlaneAddressCache()
    {
        try { WriteAtomic(_controlPlaneAddressCachePath, JsonSerializer.Serialize(_controlPlaneAddressCache.Snapshot)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { /* Live DNS answers remain usable when advisory persistence fails. */ }
    }

    private async Task ReconcileBypassRoutesAsync(ProtectedAddressSet resolved, CancellationToken cancellationToken)
    {
            var addresses = resolved.Addresses;
            var reachable = new List<IPAddress>();
            var expected = new Dictionary<IPAddress, RouteCommandResult>();
            IReadOnlyList<BypassRoute> previous;
            lock (_gate) { previous = _activeBypassRoutes; }
            var owned = new List<BypassRoute>();
            var created = new List<BypassRoute>();
            if (_routeJournalUnverified) { throw new VpnTunnelException("route_ownership_journal_invalid"); }
            try
            {
                // Re-evaluate the physical default gateway even when the IP did not
                // change. A /32 or /128 left by an old Wi-Fi interface is not reusable.
                foreach (var address in addresses)
                {
                    var result = await FindBypassRouteAsync(address, !resolved.LiteralEndpoint || !resolved.EndpointAddresses.Contains(address),
                        _nativeLocalEndpointAddresses.Contains(address), cancellationToken).ConfigureAwait(false);
                    if (result.Skipped) { continue; }
                    reachable.Add(address);
                    expected[address] = result;
                    // Native host-local routing is already outside the tunnel.
                    // A gateway host route would redirect the local endpoint.
                    if (result.Loopback || result.NativeLocal) { continue; }
                    var previousRoute = previous.FirstOrDefault(route => route.Address.Equals(address) &&
                        route.InterfaceIndex == result.InterfaceIndex && route.NextHop == result.NextHop);
                    var route = new BypassRoute(IPAddress.Parse(result.Address), result.InterfaceIndex, result.NextHop,
                        RandomNumberGenerator.GetInt32(128, 65536), Guid.NewGuid().ToString("N"));
                    if (result.Created)
                    {
                        created.Add(route);
                        SetOwnedRoutes(previous.Concat(created));
                        if (!await InstallBypassRouteAsync(route, cancellationToken).ConfigureAwait(false))
                        {
                            created.Remove(route);
                        }
                        else
                        {
                            if (!HasCreationReceipt(route)) { throw new VpnTunnelException("route_creation_unconfirmed"); }
                            created.Remove(route);
                            route = route with { Confirmed = true };
                            created.Add(route);
                        }
                    }
                    else if (previousRoute is not null && HasCreationReceipt(previousRoute) &&
                        previousRoute.RouteMetric == result.RouteMetric && IsNetMgmt(result.Protocol))
                    {
                        route = previousRoute with { Confirmed = true };
                    }
                    if (created.Contains(route) || (previousRoute is not null && route.CreationId == previousRoute.CreationId && HasCreationReceipt(route)))
                    {
                        owned.Add(route);
                    }
                    SetOwnedRoutes(previous.Concat(created));
                }
                if (!reachable.Any(address => resolved.EndpointAddresses.Contains(address)))
                {
                    throw new VpnTunnelException("endpoint_physical_route_missing");
                }
                await RemoveRoutesAsync(previous.Where(old => !owned.Any(current => SameOwnership(old, current))), cancellationToken).ConfigureAwait(false);
                SetOwnedRoutes(owned);
                // An independently owned more-specific/lower-metric route may
                // win even on the same NIC. Never delete it or claim protection.
                foreach (var address in resolved.EndpointAddresses.Where(expected.ContainsKey))
                {
                    var route = expected[address];
                    if (!route.Loopback && !route.NativeLocal)
                    {
                        await VerifyEffectiveRouteAsync(address, route, cancellationToken).ConfigureAwait(false);
                    }
                }
                lock (_gate) { _expectedBypassRoutes = expected; }
                if (_firewallArmed)
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(_firewallStatePath));
                    if (document.RootElement.ValueKind == JsonValueKind.Array)
                    {
                        // A legacy journal can be cleaned/upgraded by the next Arm call;
                        // never advertise its old permissive policy as verified.
                        SetFirewallStatus(armed: true, verified: false);
                    }
                    else
                    {
                        await RefreshFirewallBypassAsync(resolved with
                        {
                            Addresses = reachable.ToArray(),
                            EndpointAddresses = resolved.EndpointAddresses.Where(reachable.Contains).ToArray(),
                            ControlPlaneAddresses = resolved.ControlPlaneAddresses.Where(reachable.Contains).ToArray(),
                        }, cancellationToken).ConfigureAwait(false);
                    }
                }
            }
            catch
            {
                // Never remove an existing route belonging to another application.
                // Persist all our possibly remaining routes before rollback attempts.
                SetOwnedRoutes(previous.Concat(created));
                try
                {
                    using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    await RemoveRoutesAsync(created, cleanup.Token).ConfigureAwait(false);
                    SetOwnedRoutes(previous);
                }
                catch { /* The journal remains available for the next cleanup. */ }
                lock (_gate) { _expectedBypassRoutes = new Dictionary<IPAddress, RouteCommandResult>(); }
                throw;
            }
    }

    public async Task RollbackAsync(CancellationToken cancellationToken)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await DisarmFirewallCoreAsync(cancellationToken).ConfigureAwait(false);
            if (_routeJournalUnverified) { throw new VpnTunnelException("route_ownership_journal_invalid"); }
            IReadOnlyList<BypassRoute> routes;
            lock (_gate) { routes = _activeBypassRoutes; }
            await RemoveRoutesAsync(routes, cancellationToken).ConfigureAwait(false);
            SetOwnedRoutes([]);
            lock (_gate) { _expectedBypassRoutes = new Dictionary<IPAddress, RouteCommandResult>(); }
        }
        finally { _operationGate.Release(); }
    }

    public VpnTunnelDiagnostics Capture(
        NetworkInterface? adapter,
        string? endpoint,
        bool expectsIpv6,
        IReadOnlyList<string>? allowedIps = null,
        IReadOnlyList<string>? expectedDns = null,
        string? serverPublicKey = null)
    {
        bool armed;
        bool verified;
        lock (_gate)
        {
            armed = _firewallArmed;
            verified = _firewallVerified &&
                DateTimeOffset.UtcNow - _firewallVerifiedAt <= FirewallVerificationLifetime;
        }
        if (armed) { RequestFirewallVerification(); }
        if (adapter is null)
        {
            return VpnTunnelDiagnostics.Empty with
            {
                Endpoint = endpoint,
                LeakProtection = armed
                    ? verified ? VpnLeakProtectionState.Blocking : VpnLeakProtectionState.Degraded
                    : VpnLeakProtectionState.Off,
                Findings = armed && !verified
                    ? ["tunnel_adapter_missing", "firewall_policy_unverified"]
                    : ["tunnel_adapter_missing"],
            };
        }

        var properties = adapter.GetIPProperties();
        var ipv4Index = properties.GetIPv4Properties()?.Index;
        var ipv6Index = properties.GetIPv6Properties()?.Index;
        var dnsServers = properties.DnsAddresses.Select(address => address.ToString())
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var statistics = adapter.GetIPv4Statistics();
        var probes = RouteProbes(allowedIps ?? (expectsIpv6 ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"]));
        var ipv4RouteOk = probes.Where(address => address.AddressFamily == AddressFamily.InterNetwork)
            .All(address => ipv4Index is not null && BestInterface(address) == ipv4Index);
        var ipv6RouteOk = probes.Where(address => address.AddressFamily == AddressFamily.InterNetworkV6)
            .All(address => ipv6Index is not null && BestInterface(address) == ipv6Index);
        var dnsConfigured = dnsServers.Length > 0 &&
            (expectedDns is null || dnsServers.ToHashSet(StringComparer.OrdinalIgnoreCase)
                .SetEquals(expectedDns.Select(NormalizeAddress)));
        var endpointBypassOk = EndpointBypassesAdapter(endpoint, ipv4Index, ipv6Index, serverPublicKey);
        var findings = new List<string>();
        if (!ipv4RouteOk) { findings.Add("ipv4_route_missing"); }
        if (!ipv6RouteOk) { findings.Add("ipv6_route_missing"); }
        if (!dnsConfigured) { findings.Add("dns_configuration_mismatch"); }
        if (!endpointBypassOk) { findings.Add("endpoint_bypass_missing"); }
        if (armed && !verified) { findings.Add("firewall_policy_unverified"); }

        return new VpnTunnelDiagnostics(
            adapter.Name, ipv4Index, endpoint, statistics.BytesReceived, statistics.BytesSent,
            LatestHandshakeAt: null, ipv4RouteOk, ipv6RouteOk, dnsConfigured, endpointBypassOk,
            LeakProtection: !armed ? VpnLeakProtectionState.Off
                : !verified ? VpnLeakProtectionState.Degraded
                : findings.Count == 0 ? VpnLeakProtectionState.Armed : VpnLeakProtectionState.Blocking,
            dnsServers, findings);
    }

    public bool CleanupVerified()
    {
        lock (_gate)
        {
            return _activeBypassRoutes.Count == 0 && !_firewallArmed &&
                !File.Exists(_routeStatePath) && !File.Exists(_firewallStatePath);
        }
    }

    public async Task ArmFirewallAsync(string adapterName, string endpoint, CancellationToken cancellationToken,
        string? serverPublicKey = null, DateTimeOffset? authorizationExpiresAt = null)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var resolved = await ResolveProtectedAddressesAsync(endpoint, cancellationToken, serverPublicKey, authorizationExpiresAt).ConfigureAwait(false);
            if (_firewallArmed)
            {
                using var document = JsonDocument.Parse(File.ReadAllText(_firewallStatePath));
                if (document.RootElement.ValueKind == JsonValueKind.Array)
                {
                    // Upgrade the profile-only journal only after its cleanup succeeds.
                    await DisarmFirewallCoreAsync(cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await RefreshFirewallBypassAsync(resolved, cancellationToken, adapterName).ConfigureAwait(false);
                    return;
                }
            }
            var prefix = $"VEX.AntiLeak.{Guid.NewGuid():N}.";
            var names = new[] { prefix + "Tunnel", prefix + "Protected", prefix + "Dhcp4", prefix + "Dhcp6", prefix + "Neighbor", prefix + "ControlPlane" };
            const string captureScript = """
                $ErrorActionPreference='Stop'
                $profiles=@(Get-NetFirewallProfile -PolicyStore PersistentStore | Select-Object Name,@{Name='Enabled';Expression={$_.Enabled.ToString()}},@{Name='DefaultOutboundAction';Expression={$_.DefaultOutboundAction.ToString()}})
                $rules=@(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Direction -eq 'Outbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True'} | Select-Object -ExpandProperty Name)
                $ownedNames=ConvertFrom-Json $args[0];$protectedAddresses=ConvertFrom-Json $args[2];$endpointAddresses=ConvertFrom-Json $args[3];$controlAddresses=ConvertFrom-Json $args[5]
                [pscustomobject]@{Version=3;Profiles=$profiles;DisabledOutboundAllowRuleNames=$rules;OwnedRuleNames=@($ownedNames);AdapterName=$args[1];ProtectedAddresses=@($protectedAddresses);EndpointAddresses=@($endpointAddresses);EndpointPort=[int]$args[4];ControlPlaneAddresses=@($controlAddresses)} | ConvertTo-Json -Compress -Depth 5
                """;
            var rollbackJson = await _commandRunner(captureScript,
                [JsonSerializer.Serialize(names), adapterName, JsonSerializer.Serialize(resolved.Addresses.Select(address => address.ToString())),
                    JsonSerializer.Serialize(resolved.EndpointAddresses.Select(address => address.ToString())),
                    resolved.EndpointPort.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    JsonSerializer.Serialize(resolved.ControlPlaneAddresses.Select(address => address.ToString()))], cancellationToken).ConfigureAwait(false);
            var rollback = ParseFirewallRollback(rollbackJson);
            // The complete ownership/restore journal is durable before any mutation.
            WriteAtomic(_firewallStatePath, rollbackJson);
            SetFirewallStatus(armed: true, verified: false);
            try
            {
                const string armScript = """
                    $ErrorActionPreference='Stop'
                    $state=ConvertFrom-Json $args[0];$names=@($state.OwnedRuleNames)
                    Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -cin @($state.DisabledOutboundAllowRuleNames)} | Disable-NetFirewallRule | Out-Null
                    New-NetFirewallRule -Name $names[0] -DisplayName 'VEX VPN tunnel' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -InterfaceAlias $state.AdapterName -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[1] -DisplayName 'VEX VPN protected endpoints' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol UDP -RemotePort $state.EndpointPort -RemoteAddress @($state.EndpointAddresses) -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[2] -DisplayName 'VEX VPN DHCPv4' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol UDP -LocalPort 68 -RemotePort 67 -Program ($env:SystemRoot+'\System32\svchost.exe') -Service Dhcp -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[3] -DisplayName 'VEX VPN DHCPv6' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol UDP -LocalPort 546 -RemotePort 547 -Program ($env:SystemRoot+'\System32\svchost.exe') -Service Dhcp -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[4] -DisplayName 'VEX VPN IPv6 neighbors' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol ICMPv6 -IcmpType 133,135,136 -RemoteAddress 'fe80::/10','ff02::/16' -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    $control=@($state.ControlPlaneAddresses);$controlEnabled=if($control.Count -gt 0){'True'}else{'False'};if($control.Count -eq 0){$control=@('127.0.0.1')}
                    New-NetFirewallRule -Name $names[5] -DisplayName 'VEX VPN control plane HTTPS' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol TCP -RemotePort 443 -RemoteAddress $control -Enabled $controlEnabled -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    Set-NetFirewallProfile -Profile Domain,Private,Public -PolicyStore PersistentStore -Enabled True -DefaultOutboundAction Block
                    """;
                await _commandRunner(armScript, [rollbackJson], cancellationToken).ConfigureAwait(false);
                await VerifyFirewallAsync(rollback, cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                SetFirewallStatus(armed: true, verified: false);
                // Cancellation also kills the PowerShell process before this restore.
                await RestoreFirewallAsync(rollbackJson, CancellationToken.None).ConfigureAwait(false);
                File.Delete(_firewallStatePath);
                SetFirewallStatus(armed: false, verified: false);
                throw;
            }
        }
        finally { _operationGate.Release(); }
    }

    public async Task DisarmFirewallOnlyAsync(CancellationToken cancellationToken)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await DisarmFirewallCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _operationGate.Release(); }
    }

    private async Task DisarmFirewallCoreAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_firewallStatePath))
        {
            SetFirewallStatus(armed: false, verified: false);
            return;
        }
        SetFirewallStatus(armed: true, verified: false);
        await RestoreFirewallAsync(File.ReadAllText(_firewallStatePath), cancellationToken).ConfigureAwait(false);
        File.Delete(_firewallStatePath);
        SetFirewallStatus(armed: false, verified: false);
    }

    private async Task RefreshFirewallBypassAsync(ProtectedAddressSet resolved, CancellationToken cancellationToken, string? adapterName = null)
    {
        SetFirewallStatus(armed: true, verified: false);
        var state = ParseFirewallRollback(File.ReadAllText(_firewallStatePath));
        state = state with
        {
            Version = 3,
            // Preserve the exact original baseline when narrowing an armed v2
            // journal. Disarming and recapturing would restore broad allows.
            OwnedRuleNames = state.Version == 2 ? state.OwnedRuleNames.Append(state.OwnedRuleNames[0] + ".ControlPlane").ToArray() : state.OwnedRuleNames,
            AdapterName = adapterName ?? state.AdapterName,
            ProtectedAddresses = resolved.Addresses.Select(address => address.ToString()).ToArray(),
            EndpointAddresses = resolved.EndpointAddresses.Select(address => address.ToString()).ToArray(),
            EndpointPort = resolved.EndpointPort,
            ControlPlaneAddresses = resolved.ControlPlaneAddresses.Select(address => address.ToString()).ToArray(),
        };
        WriteAtomic(_firewallStatePath, JsonSerializer.Serialize(state));
        const string script = """
            # Narrow an existing owned policy, including version 2, without recapturing the baseline.
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0];$names=@($state.OwnedRuleNames)
            $rule=Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -ceq $names[1]}
            if(@($rule).Count -ne 1){throw 'firewall_owned_rule_missing'}
            $rule | Set-NetFirewallRule -Protocol UDP -RemotePort $state.EndpointPort -RemoteAddress @($state.EndpointAddresses) | Out-Null
            Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -ceq $names[0]} | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias $state.AdapterName | Out-Null
            $control=@($state.ControlPlaneAddresses);$enabled=if($control.Count -gt 0){'True'}else{'False'};if($control.Count -eq 0){$control=@('127.0.0.1')}
            $controlRule=@(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -ceq $names[5]})
            if($controlRule.Count -eq 0){
                New-NetFirewallRule -Name $names[5] -DisplayName 'VEX VPN control plane HTTPS' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol TCP -RemotePort 443 -RemoteAddress $control -Enabled $enabled -InterfaceType Wired,Wireless -Profile Any | Out-Null
            }elseif($controlRule.Count -eq 1){
                $controlRule | Set-NetFirewallRule -Protocol TCP -RemotePort 443 -RemoteAddress $control -Enabled $enabled | Out-Null
            }else{throw 'firewall_owned_rule_duplicate'}
            """;
        await _commandRunner(script, [JsonSerializer.Serialize(state)], cancellationToken).ConfigureAwait(false);
        await VerifyFirewallAsync(state, cancellationToken).ConfigureAwait(false);
    }

    private async Task VerifyFirewallAsync(FirewallRollback state, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0];$names=@($state.OwnedRuleNames)
            function Same-Set($actual,$expected){
                $a=@($actual | ForEach-Object {$_.ToString().Split(',') | ForEach-Object {$_.Trim()}} | Sort-Object -Unique)
                $e=@($expected | ForEach-Object {$_.ToString()} | Sort-Object -Unique)
                return ($a.Count -eq $e.Count -and @($a | Where-Object {$_ -cnotin $e}).Count -eq 0)
            }
            if((Get-Service MpsSvc).Status -ne 'Running'){throw 'firewall_service_inactive'}
            $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
            if($profiles.Count -ne 3 -or @( $profiles | Where-Object {$_.Enabled -ne 'True' -or $_.DefaultOutboundAction -ne 'Block'}).Count -ne 0){throw 'firewall_effective_profile_unverified'}
            if($state.Version -ne 3){throw 'firewall_policy_version_unverified'}
            $rules=@(Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object {$_.Direction -eq 'Outbound' -and $_.Action -eq 'Allow'})
            if(@($rules | Where-Object {$_.Enabled -eq 'True' -and $_.Name -cnotin $names}).Count -ne 0){throw 'firewall_external_allow_active'}
            foreach($name in $names){if(@($rules | Where-Object {$_.Name -ceq $name}).Count -ne 1){throw 'firewall_owned_allow_missing'}}
            if(@($rules | Where-Object {$_.Name -cin $names[0..4] -and $_.Enabled -ne 'True'}).Count -ne 0){throw 'firewall_owned_allow_disabled'}
            $tunnel=$rules | Where-Object {$_.Name -ceq $names[0]}
            if(!(Same-Set @($tunnel | Get-NetFirewallInterfaceFilter | Select-Object -ExpandProperty InterfaceAlias) @($state.AdapterName))){throw 'firewall_tunnel_interface_unverified'}
            $protected=$rules | Where-Object {$_.Name -ceq $names[1]}
            $remote=@($protected | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress | ForEach-Object {[System.Net.IPAddress]::Parse($_).ToString()})
            if(!(Same-Set $remote @($state.EndpointAddresses))){throw 'firewall_protected_addresses_unverified'}
            $endpointPort=$protected | Get-NetFirewallPortFilter
            if($endpointPort.Protocol -notin @('17','UDP') -or !(Same-Set @($endpointPort.RemotePort) @($state.EndpointPort))){throw 'firewall_endpoint_ports_unverified'}
            $control=$rules | Where-Object {$_.Name -ceq $names[5]};$controlPort=$control | Get-NetFirewallPortFilter
            if($controlPort.Protocol -notin @('6','TCP') -or !(Same-Set @($controlPort.RemotePort) @('443'))){throw 'firewall_control_ports_unverified'}
            $controlAddresses=@($state.ControlPlaneAddresses);$controlEnabled=if($controlAddresses.Count -gt 0){'True'}else{'False'};if($controlAddresses.Count -eq 0){$controlAddresses=@('127.0.0.1')}
            if($control.Enabled -ne $controlEnabled){throw 'firewall_control_enabled_unverified'}
            if(!(Same-Set @($control | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress) $controlAddresses)){throw 'firewall_control_addresses_unverified'}
            foreach($i in 1..5){
                $rule=$rules | Where-Object {$_.Name -ceq $names[$i]}
                if(!(Same-Set @($rule | Get-NetFirewallInterfaceTypeFilter | Select-Object -ExpandProperty InterfaceType) @('Wired','Wireless'))){throw 'firewall_physical_interface_unverified'}
            }
            foreach($i in 2..3){
                $rule=$rules | Where-Object {$_.Name -ceq $names[$i]};$port=$rule | Get-NetFirewallPortFilter
                $local=if($i -eq 2){'68'}else{'546'};$remote=if($i -eq 2){'67'}else{'547'}
                if($port.Protocol -notin @('17','UDP') -or !(Same-Set @($port.LocalPort) @($local)) -or !(Same-Set @($port.RemotePort) @($remote))){throw 'firewall_dhcp_ports_unverified'}
                if(($rule | Get-NetFirewallServiceFilter).Service -ne 'Dhcp'){throw 'firewall_dhcp_service_unverified'}
                if(($rule | Get-NetFirewallApplicationFilter).Program -ine ($env:SystemRoot+'\System32\svchost.exe')){throw 'firewall_dhcp_program_unverified'}
            }
            $neighbor=$rules | Where-Object {$_.Name -ceq $names[4]};$port=$neighbor | Get-NetFirewallPortFilter
            $types=@($port.IcmpType | ForEach-Object {$_.ToString().Split(':')[0]})
            if($port.Protocol -notin @('58','ICMPv6') -or !(Same-Set $types @('133','135','136'))){throw 'firewall_neighbor_protocol_unverified'}
            if(!(Same-Set @($neighbor | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress) @('fe80::/10','ff02::/16'))){throw 'firewall_neighbor_addresses_unverified'}
            'ok'
            """;
        try
        {
            var result = await _commandRunner(script, [JsonSerializer.Serialize(state)], cancellationToken).ConfigureAwait(false);
            if (result != "ok") { throw new VpnTunnelException("firewall_policy_unverified"); }
            SetFirewallStatus(armed: true, verified: true);
        }
        catch
        {
            SetFirewallStatus(armed: true, verified: false);
            throw;
        }
    }

    private void RequestFirewallVerification()
    {
        lock (_gate)
        {
            if (_firewallVerified && DateTimeOffset.UtcNow - _firewallVerifiedAt < TimeSpan.FromSeconds(10)) { return; }
        }
        if (Interlocked.CompareExchange(ref _verificationPending, 1, 0) != 0) { return; }
        _ = VerifyInBackgroundAsync();
    }

    private async Task VerifyInBackgroundAsync()
    {
        await _operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_firewallArmed)
            {
                await VerifyFirewallAsync(ParseFirewallRollback(File.ReadAllText(_firewallStatePath)), CancellationToken.None).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (error is VpnTunnelException or IOException or JsonException or UnauthorizedAccessException or Win32Exception)
        {
            SetFirewallStatus(armed: true, verified: false);
        }
        finally
        {
            _operationGate.Release();
            Interlocked.Exchange(ref _verificationPending, 0);
        }
    }

    private void SetFirewallStatus(bool armed, bool verified)
    {
        lock (_gate)
        {
            _firewallArmed = armed;
            _firewallVerified = verified;
            if (verified) { _firewallVerifiedAt = DateTimeOffset.UtcNow; }
        }
    }

    private static FirewallRollback ParseFirewallRollback(string json)
    {
        var state = JsonSerializer.Deserialize<FirewallRollback>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        if (state is null || state.Version is not (2 or 3) || state.Profiles is not { Length: 3 } ||
            state.OwnedRuleNames is null || state.OwnedRuleNames.Length != (state.Version == 2 ? 5 : 6) ||
            state.DisabledOutboundAllowRuleNames is null || state.ProtectedAddresses is not { Length: > 0 } || string.IsNullOrWhiteSpace(state.AdapterName) ||
            state.OwnedRuleNames.Any(name => string.IsNullOrWhiteSpace(name) || !name.StartsWith("VEX.AntiLeak.", StringComparison.Ordinal)) ||
            state.OwnedRuleNames.Distinct(StringComparer.Ordinal).Count() != state.OwnedRuleNames.Length ||
            (state.Version == 3 && (state.EndpointPort is < 1 or > 65535 || state.EndpointAddresses is not { Length: > 0 } ||
                state.ControlPlaneAddresses is null || state.EndpointAddresses.Concat(state.ControlPlaneAddresses).Any(value => !IPAddress.TryParse(value, out _)))))
        {
            throw new VpnTunnelException("firewall_rollback_state_invalid");
        }
        return state;
    }

    private async Task RestoreFirewallAsync(string rollbackJson, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0]
            if($state.Version -in @(2,3)){
                $profiles=@($state.Profiles);$names=@($state.OwnedRuleNames);$disabled=@($state.DisabledOutboundAllowRuleNames)
                Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -cin $names} | Remove-NetFirewallRule
                $rules=@(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -cin $disabled})
                $rules | Enable-NetFirewallRule | Out-Null
            }else{
                # Migration of the old profile-only journal: recognize only the old VEX display names.
                $profiles=@($state);$disabled=@();$names=@(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object {$_.Group -eq 'VEX VPN AntiLeak' -and ($_.DisplayName -eq 'VEX VPN tunnel' -or $_.DisplayName -match '^VEX VPN bypass [0-9.]+$')} | Select-Object -ExpandProperty Name)
                Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -cin $names} | Remove-NetFirewallRule
            }
            foreach($profile in $profiles){
                Set-NetFirewallProfile -Profile $profile.Name -PolicyStore PersistentStore -DefaultOutboundAction $profile.DefaultOutboundAction
                if($null -ne $profile.Enabled){Set-NetFirewallProfile -Profile $profile.Name -PolicyStore PersistentStore -Enabled $profile.Enabled}
            }
            $actual=@(Get-NetFirewallProfile -PolicyStore PersistentStore)
            foreach($profile in $profiles){
                $value=$actual | Where-Object Name -eq $profile.Name
                if($value.DefaultOutboundAction.ToString() -ne $profile.DefaultOutboundAction.ToString()){throw 'firewall_profile_restore_failed'}
                if($null -ne $profile.Enabled -and $value.Enabled.ToString() -ne $profile.Enabled.ToString()){throw 'firewall_enabled_restore_failed'}
            }
            $remaining=@(Get-NetFirewallRule -PolicyStore PersistentStore)
            if(@($remaining | Where-Object {$_.Name -cin $names}).Count -ne 0){throw 'firewall_owned_rule_cleanup_failed'}
            if(@($remaining | Where-Object {$_.Name -cin $disabled -and $_.Enabled -ne 'True'}).Count -ne 0){throw 'firewall_rule_restore_failed'}
            'ok'
            """;
        var result = await _commandRunner(script, [rollbackJson], cancellationToken).ConfigureAwait(false);
        if (result != "ok") { throw new VpnTunnelException("firewall_restore_unverified"); }
    }

    private IReadOnlyList<BypassRoute> LoadPersistedRoutes()
    {
        try
        {
            if (new FileInfo(_routeStatePath).Length > 256 * 1024) { throw new JsonException(); }
            using var document = JsonDocument.Parse(File.ReadAllText(_routeStatePath));
            var legacy = document.RootElement.ValueKind == JsonValueKind.Array;
            var journal = legacy ? null : JsonSerializer.Deserialize<BypassRouteJournal>(document.RootElement);
            var entries = legacy ? JsonSerializer.Deserialize<PersistedBypassRoute[]>(document.RootElement)
                : journal is { Version: 2 } ? journal.Entries : throw new JsonException();
            if (entries is null || entries.Length > 512) { throw new JsonException(); }
            var routes = new List<BypassRoute>();
            foreach (var entry in entries)
            {
                var ambiguousLegacy = legacy || entry?.Legacy == true;
                if (entry is null || !IPAddress.TryParse(entry.Address, out var address) || entry.InterfaceIndex <= 0 ||
                    !IPAddress.TryParse(entry.NextHop, out _) ||
                    (!ambiguousLegacy && (entry.RouteMetric is < 128 or > 65535 || !Guid.TryParseExact(entry.CreationId, "N", out _))) ||
                    (!legacy && ambiguousLegacy && (entry.RouteMetric != 0 || entry.CreationId is not null || entry.Confirmed)))
                { throw new JsonException(); }
                routes.Add(new BypassRoute(address, entry.InterfaceIndex, entry.NextHop,
                    ambiguousLegacy ? 0 : entry.RouteMetric, ambiguousLegacy ? null : entry.CreationId, !ambiguousLegacy && entry.Confirmed));
            }
            return routes;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return []; }
        catch (Exception error) when (error is JsonException or FormatException)
        {
            _routeJournalUnverified = true;
            return [];
        }
    }

    private void SetOwnedRoutes(IEnumerable<BypassRoute> routes)
    {
        var owned = routes.GroupBy(route => (route.Address, route.InterfaceIndex, route.NextHop, route.CreationId))
            .Select(group => group.OrderByDescending(route => route.Confirmed).First()).ToArray();
        PersistRoutes(owned);
        lock (_gate) { _activeBypassRoutes = owned; }
    }

    private void PersistRoutes(IEnumerable<BypassRoute> routes)
    {
        if (_routeJournalUnverified) { throw new VpnTunnelException("route_ownership_journal_invalid"); }
        var entries = routes.Distinct().Select(route => new PersistedBypassRoute(route.Address.ToString(), route.InterfaceIndex,
            route.NextHop, route.RouteMetric, route.CreationId, route.Confirmed, route.CreationId is null)).ToArray();
        if (entries.Length == 0) { File.Delete(_routeStatePath); return; }
        WriteAtomic(_routeStatePath, JsonSerializer.Serialize(new BypassRouteJournal(2, entries)));
    }

    private string ReceiptPath(BypassRoute route) => route.CreationId is not null && Guid.TryParseExact(route.CreationId, "N", out _)
        ? Path.Combine(_routeReceiptsDirectory, route.CreationId + ".json") : "";

    private static bool IsNetMgmt(string? protocol) => protocol is "NetMgmt" or "3";

    private static bool SameOwnership(BypassRoute left, BypassRoute right) => left.Address.Equals(right.Address) &&
        left.InterfaceIndex == right.InterfaceIndex && left.NextHop == right.NextHop &&
        left.RouteMetric == right.RouteMetric && left.CreationId == right.CreationId;

    private bool HasCreationReceipt(BypassRoute route)
    {
        try
        {
            var path = ReceiptPath(route);
            if (path.Length == 0 || new FileInfo(path) is not { Exists: true, Length: <= 4096 }) { return false; }
            var receipt = JsonSerializer.Deserialize<BypassRouteReceipt>(File.ReadAllText(path));
            return receipt is not null && receipt.CreationId == route.CreationId && receipt.Address == route.Address.ToString() &&
                receipt.InterfaceIndex == route.InterfaceIndex && receipt.NextHop == route.NextHop &&
                receipt.RouteMetric == route.RouteMetric && IsNetMgmt(receipt.Protocol);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }

    private static void WriteAtomic(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                writer.Write(value);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally { File.Delete(temporaryPath); }
    }

    private static string NormalizeAddress(string value) => IPAddress.TryParse(value, out var address) ? address.ToString() : value;

    private static IReadOnlyList<IPAddress> RouteProbes(IReadOnlyList<string> ranges)
    {
        var probes = new List<IPAddress>();
        foreach (var range in ranges)
        {
            var parts = range.Split('/');
            if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var network) || !int.TryParse(parts[1], out var prefix))
            {
                throw new VpnTunnelException("invalid_tunnel_allowed_ips");
            }
            var bits = network.AddressFamily == AddressFamily.InterNetwork ? 32 : 128;
            if (prefix < 0 || prefix > bits) { throw new VpnTunnelException("invalid_tunnel_allowed_ips"); }
            if (prefix == 0)
            {
                probes.Add(IPAddress.Parse(bits == 32 ? "1.1.1.1" : "2606:4700:4700::1111"));
                continue;
            }
            var bytes = network.GetAddressBytes();
            for (var bit = prefix; bit < bits; bit++) { bytes[bit / 8] &= (byte)~(1 << (7 - bit % 8)); }
            if (prefix < bits) { bytes[^1] |= 1; }
            probes.Add(new IPAddress(bytes));
        }
        return probes;
    }

    private bool EndpointBypassesAdapter(string? endpoint, int? ipv4TunnelIndex, int? ipv6TunnelIndex,
        string? serverPublicKey)
    {
        if (string.IsNullOrWhiteSpace(endpoint)) { return false; }
        try
        {
            var host = ParseEndpointHost(endpoint);
            // Status must never wait on DNS while holding the runtime gate.
            var addresses = IPAddress.TryParse(host, out var address) ? [address]
                : _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow).ToArray();
            IReadOnlyDictionary<IPAddress, RouteCommandResult> expected;
            lock (_gate) { expected = _expectedBypassRoutes; }
            var qualified = addresses.Where(expected.ContainsKey).ToArray();
            return qualified.Length > 0 && qualified.All(candidate =>
                EffectiveRouteMatches(candidate, expected[candidate], ipv4TunnelIndex, ipv6TunnelIndex));
        }
        catch (Exception error) when (error is SocketException or VpnTunnelException or ArgumentException) { return false; }
    }

    private static bool EffectiveRouteMatches(IPAddress address, RouteCommandResult expected,
        int? ipv4TunnelIndex, int? ipv6TunnelIndex)
    {
        var tunnelIndex = address.AddressFamily == AddressFamily.InterNetwork ? ipv4TunnelIndex : ipv6TunnelIndex;
        if (expected.Loopback || expected.NativeLocal)
        {
            // The fixture-only native-host endpoint is already assigned to an
            // active physical NIC; installing a gateway route would break it.
            var localIndex = BestInterface(address);
            return localIndex is not null && localIndex != tunnelIndex;
        }
        var destination = NativeSocketAddress.From(address);
        if (GetBestRoute2(IntPtr.Zero, 0, IntPtr.Zero, ref destination, 0, out var route, out _) != 0)
        {
            return false;
        }
        var actualHop = route.NextHop.ToAddress();
        return route.InterfaceIndex == expected.InterfaceIndex && route.InterfaceIndex != tunnelIndex &&
            IPAddress.TryParse(expected.NextHop, out var expectedHop) && actualHop is not null &&
            actualHop.GetAddressBytes().AsSpan().SequenceEqual(expectedHop.GetAddressBytes());
    }

    private static int? BestInterface(IPAddress address)
    {
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(), 0), out var index) == 0 ? checked((int)index) : null;
        }
        var socketAddress = new SockaddrIn6
        {
            Family = (short)AddressFamily.InterNetworkV6,
            Address = address.GetAddressBytes(),
            ScopeId = checked((uint)address.ScopeId),
        };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<SockaddrIn6>());
        try
        {
            Marshal.StructureToPtr(socketAddress, pointer, false);
            return GetBestInterfaceEx(pointer, out var index) == 0 ? checked((int)index) : null;
        }
        finally { Marshal.FreeHGlobal(pointer); }
    }

    private async Task<ProtectedAddressSet> ResolveProtectedAddressesAsync(string endpoint, CancellationToken cancellationToken,
        string? serverPublicKey, DateTimeOffset? authorizationExpiresAt)
    {
        var endpointHost = ParseEndpointHost(endpoint);
        var addresses = new HashSet<IPAddress>();
        var endpointAddresses = new HashSet<IPAddress>();
        var controlAddresses = new HashSet<IPAddress>();
        var cachedControl = _controlPlaneAddressCache.Get(endpoint, serverPublicKey, _controlPlaneHosts,
            authorizationExpiresAt, DateTimeOffset.UtcNow);
        var hosts = _controlPlaneHosts.Prepend(endpointHost).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        // Independent names share one bounded resolution window rather than
        // accumulating an OS resolver timeout for every host.
        var results = await Task.WhenAll(hosts.Select(async host =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            IPAddress[] resolved;
            var fresh = true;
            try
            {
                resolved = IPAddress.TryParse(host, out var parsed) ? [parsed]
                    : await BoundedDnsResolver.ResolveAsync(host, _dnsResolver,
                        DnsResolutionTimeout, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is SocketException || error is VpnTunnelException { Code: "endpoint_resolution_timeout" })
            {
                fresh = false;
                resolved = host == endpointHost
                    ? _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow)
                        .Concat(cachedControl.GetValueOrDefault(host, [])).Distinct().Take(16).ToArray()
                    : cachedControl.GetValueOrDefault(host, []);
            }
            var freshAnswer = fresh ? resolved.Take(16).ToArray() : [];
            if (host == endpointHost && !IPAddress.TryParse(host, out _))
            {
                // A fresh authenticated peer may still use an earlier answer.
                // Keep that exact-scope address until the signed lease expires.
                resolved = _endpointAddressCache.Get(endpoint, serverPublicKey, DateTimeOffset.UtcNow)
                    .Concat(resolved).Distinct().Take(16).ToArray();
            }
            return (Host: host, Addresses: resolved.Take(16).ToArray(), FreshAnswer: freshAnswer);
        })).ConfigureAwait(false);
        var freshControl = new Dictionary<string, IPAddress[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var (host, resolved, freshAnswer) in results)
        {
            if (freshAnswer.Length > 0 && _controlPlaneHosts.Contains(host, StringComparer.OrdinalIgnoreCase))
            { freshControl[host] = freshAnswer; }
            if (host == endpointHost && resolved.Length == 0) { throw new VpnTunnelException("endpoint_resolution_failed"); }
            foreach (var address in resolved)
            {
                if (address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
                {
                    addresses.Add(address);
                    if (host == endpointHost) { endpointAddresses.Add(address); }
                    if (_controlPlaneHosts.Contains(host, StringComparer.OrdinalIgnoreCase)) { controlAddresses.Add(address); }
                }
            }
        }
        if (_controlPlaneAddressCache.Remember(endpoint, serverPublicKey, _controlPlaneHosts, freshControl,
            authorizationExpiresAt, DateTimeOffset.UtcNow)) { PersistControlPlaneAddressCache(); }
        if (addresses.Count == 0) { throw new VpnTunnelException("endpoint_resolution_failed"); }
        return new ProtectedAddressSet(addresses.ToArray(), endpointAddresses.ToArray(),
            IPAddress.TryParse(endpointHost, out _), ParseEndpointPort(endpoint), controlAddresses.ToArray());
    }

    private static int ParseEndpointPort(string endpoint) => VpnEndpointAddressCache.TryParseEndpoint(endpoint, out _, out var port)
        ? port : throw new VpnTunnelException("endpoint_invalid");

    private static string ParseEndpointHost(string endpoint)
    {
        var value = endpoint.Trim();
        if (IPAddress.TryParse(value, out _)) { return value; }
        if (value.StartsWith('['))
        {
            var closing = value.IndexOf(']');
            if (closing <= 1 || !IPAddress.TryParse(value[1..closing], out _)) { throw new VpnTunnelException("endpoint_invalid"); }
            return value[1..closing];
        }
        var separator = value.LastIndexOf(':');
        var host = separator > 0 ? value[..separator] : value;
        if (string.IsNullOrWhiteSpace(host) || host.Contains(':') || Uri.CheckHostName(host) == UriHostNameType.Unknown)
        {
            throw new VpnTunnelException("endpoint_invalid");
        }
        return host;
    }

    private async Task<RouteCommandResult> FindBypassRouteAsync(IPAddress address, bool allowMissingPhysical,
        bool nativeLocalEndpoint, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$ip=$args[0];$family=$args[1];$prefix=$ip+'/'+$args[2]
            if([System.Net.IPAddress]::IsLoopback([System.Net.IPAddress]::Parse($ip))){
                [pscustomobject]@{Address=$ip;InterfaceIndex=0;NextHop='';Created=$false;Loopback=$true} | ConvertTo-Json -Compress;return
            }
            $physical=@(Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up'} | Select-Object -ExpandProperty InterfaceIndex)
            if($args.Count -gt 4 -and $args[4] -eq 'True'){
                $local=@(Get-NetIPAddress -AddressFamily $family -IPAddress $ip -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -eq $ip -and $_.AddressState -eq 'Preferred' -and $_.InterfaceIndex -in $physical})
                if($local.Count -ne 1){throw 'native_local_endpoint_not_assigned'}
                [pscustomobject]@{Address=$ip;InterfaceIndex=$local[0].InterfaceIndex;NextHop='';Created=$false;NativeLocal=$true} | ConvertTo-Json -Compress;return
            }
            # Never use Find-NetRoute: it can choose the running tunnel or our stale host route.
            $default=if($family -eq 'IPv4'){'0.0.0.0/0'}else{'::/0'}
            $candidates=@(Get-NetRoute -AddressFamily $family -DestinationPrefix $default -PolicyStore ActiveStore | Where-Object {$_.InterfaceIndex -in $physical -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::'} | ForEach-Object {
                $interface=Get-NetIPInterface -AddressFamily $family -InterfaceIndex $_.InterfaceIndex
                [pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;NextHop=$_.NextHop;Metric=([int]$_.RouteMetric+[int]$interface.InterfaceMetric)}
            } | Sort-Object Metric,InterfaceIndex)
            $best=$candidates | Select-Object -First 1
            if($null -eq $best){
                if($args[3] -eq 'True'){[pscustomobject]@{Address=$ip;InterfaceIndex=0;NextHop='::';Created=$false;Skipped=$true} | ConvertTo-Json -Compress;return}
                throw 'physical_default_route_missing'
            }
            $existing=Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $best.InterfaceIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $best.NextHop} | Select-Object -First 1
            $metric=if($null -eq $existing){0}else{[int]$existing.RouteMetric};$protocol=if($null -eq $existing){$null}else{$existing.Protocol.ToString()}
            [pscustomobject]@{Address=$ip;InterfaceIndex=$best.InterfaceIndex;NextHop=$best.NextHop;Created=($null -eq $existing);RouteMetric=$metric;Protocol=$protocol} | ConvertTo-Json -Compress
            """;
        var output = await _commandRunner(script,
            [address.ToString(), address.AddressFamily == AddressFamily.InterNetwork ? "IPv4" : "IPv6", address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128", allowMissingPhysical.ToString(), nativeLocalEndpoint.ToString()], cancellationToken).ConfigureAwait(false);
        return JsonSerializer.Deserialize<RouteCommandResult>(output) ?? throw new VpnTunnelException("route_bypass_apply_failed");
    }

    private async Task<bool> InstallBypassRouteAsync(BypassRoute route, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$prefix=$args[0]+'/'+$args[3];$idx=[int]$args[1];$hop=$args[2]
            $existing=Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $hop} | Select-Object -First 1
            if($null -ne $existing){'existing';return}
            # Receipt proves a completed creation, not the preceding journal intent.
            $metric=[int]$args[4];$creationId=$args[5];$receiptPath=$args[6]
            New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -NextHop $hop -RouteMetric $metric -Protocol NetMgmt -PolicyStore ActiveStore | Out-Null
            $created=@(Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore | Where-Object {$_.NextHop -eq $hop -and $_.RouteMetric -eq $metric -and $_.Protocol.ToString() -in @('NetMgmt','3')})
            if($created.Count -ne 1){throw 'route_creation_unconfirmed'}
            $receipt=[pscustomobject]@{CreationId=$creationId;Address=$args[0];InterfaceIndex=$idx;NextHop=$hop;RouteMetric=$metric;Protocol='NetMgmt'}
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($receiptPath))
            $temporary=$receiptPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
            try{
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Compress))
                $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
                try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
                [IO.File]::Move($temporary,$receiptPath)
            }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
            'created'
            """;
        var result = await _commandRunner(script,
            [route.Address.ToString(), route.InterfaceIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), route.NextHop,
                route.Address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128",
                route.RouteMetric.ToString(System.Globalization.CultureInfo.InvariantCulture), route.CreationId!, ReceiptPath(route)], cancellationToken).ConfigureAwait(false);
        return result == "created";
    }

    private async Task VerifyEffectiveRouteAsync(IPAddress address, RouteCommandResult expected,
        CancellationToken cancellationToken)
    {
        const string script = """
            # Verify the effective route after owned stale routes were removed.
            $ErrorActionPreference='Stop';$ip=$args[0];$idx=[int]$args[1];$hop=[System.Net.IPAddress]::Parse($args[2])
            $selected=@(Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop | Where-Object {$null -ne $_.PSObject.Properties['NextHop']})
            if($selected.Count -ne 1 -or $selected[0].InterfaceIndex -ne $idx){throw 'endpoint_bypass_route_conflict'}
            $actual=[System.Net.IPAddress]::Parse($selected[0].NextHop)
            if(($actual.GetAddressBytes() -join ',') -cne ($hop.GetAddressBytes() -join ',')){throw 'endpoint_bypass_route_conflict'}
            'ok'
            """;
        var result = await _commandRunner(script,
            [address.ToString(), expected.InterfaceIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), expected.NextHop],
            cancellationToken).ConfigureAwait(false);
        if (result != "ok") { throw new VpnTunnelException("endpoint_bypass_route_conflict"); }
    }

    private async Task RemoveRoutesAsync(IEnumerable<BypassRoute> routes, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$prefix=$args[0]+'/'+$args[3];$idx=[int]$args[1];$hop=$args[2]
            $metric=[int]$args[4];$creationId=$args[5];$receiptPath=$args[6]
            $candidates=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {$_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $idx -and $_.NextHop -eq $hop})
            if($metric -eq 0 -or [string]::IsNullOrEmpty($creationId)){
                # Old tuple-only records cannot distinguish a replacement owner.
                if($candidates.Count -gt 0){throw 'route_legacy_ownership_unverified'}
                return
            }
            $owned=@($candidates | Where-Object {$_.RouteMetric -eq $metric -and $_.Protocol.ToString() -in @('NetMgmt','3')})
            if($owned.Count -gt 0){
                if(![IO.File]::Exists($receiptPath) -or (Get-Item -LiteralPath $receiptPath).Length -gt 4096){throw 'route_creation_receipt_missing'}
                $receipt=ConvertFrom-Json ([IO.File]::ReadAllText($receiptPath))
                if($receipt.CreationId -cne $creationId -or $receipt.Address -cne $args[0] -or $receipt.InterfaceIndex -ne $idx -or $receipt.NextHop -cne $hop -or $receipt.RouteMetric -ne $metric -or $receipt.Protocol -cne 'NetMgmt'){throw 'route_creation_receipt_invalid'}
                $owned | Remove-NetRoute -Confirm:$false -ErrorAction Stop
            }
            $remaining=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {$_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $idx -and $_.NextHop -eq $hop -and $_.RouteMetric -eq $metric -and $_.Protocol.ToString() -in @('NetMgmt','3')})
            if($remaining.Count -ne 0){throw 'route_cleanup_failed'}
            # A different fingerprint is a foreign replacement, even at the same tuple.
            if([IO.File]::Exists($receiptPath)){[IO.File]::Delete($receiptPath)}
            """;
        foreach (var route in routes.Reverse())
        {
            await _commandRunner(script,
                [route.Address.ToString(), route.InterfaceIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), route.NextHop,
                    route.Address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128",
                    route.RouteMetric.ToString(System.Globalization.CultureInfo.InvariantCulture), route.CreationId ?? "", ReceiptPath(route)], cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<string> RunPowerShellAsync(string script, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        if (arguments.Any(argument => argument.Length > 8 * 1024 * 1024 || argument.IndexOf('\0') >= 0))
        {
            throw new VpnTunnelException("network_safety_argument_invalid");
        }
        // -Command plus trailing native arguments reparses quotes/metacharacters.
        // Encode only the trusted program and pass all data as JSON through stdin.
        // Windows PowerShell 5.1 emits a JSON array as one pipeline object;
        // PowerShell 7 enumerates it. Direct assignment preserves the flat array
        // on both hosts, whereas @(ConvertFrom-Json ...) nests it on 5.1.
        var wrapper = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$vexArguments=ConvertFrom-Json ([Console]::In.ReadToEnd()); & {\n" + script + "\n} @vexArguments";
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (var option in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "AllSigned", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(wrapper)) })
        {
            startInfo.ArgumentList.Add(option);
        }
        using var process = Process.Start(startInfo) ?? throw new VpnTunnelException("network_safety_launch_failed");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CommandTimeout);
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        try
        {
            await process.StandardInput.WriteAsync(JsonSerializer.Serialize(arguments).AsMemory(), timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false);
            _ = await errorTask.ConfigureAwait(false);
            if (process.ExitCode != 0) { throw new VpnTunnelException("network_safety_command_failed"); }
            return output.Trim();
        }
        catch (OperationCanceledException)
        {
            TryTerminate(process);
            // Wait until mutation has stopped before a rollback can begin.
            using var cleanupTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try { await process.WaitForExitAsync(cleanupTimeout.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw new VpnTunnelException("network_safety_process_cleanup_failed"); }
            if (cancellationToken.IsCancellationRequested) { throw; }
            throw new VpnTunnelException("network_safety_timeout");
        }
        finally
        {
            if (!process.HasExited) { TryTerminate(process); }
        }
    }

    private static void TryTerminate(Process process)
    {
        try { process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
    }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern int GetBestInterface(uint destinationAddress, out uint bestInterfaceIndex);
    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern int GetBestInterfaceEx(IntPtr destinationAddress, out uint bestInterfaceIndex);
    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint GetBestRoute2(IntPtr interfaceLuid, uint interfaceIndex, IntPtr sourceAddress,
        ref NativeSocketAddress destinationAddress, uint addressSortOptions,
        out NativeRouteRow bestRoute, out NativeSocketAddress bestSourceAddress);

    // Windows SDK SOCKADDR_INET and MIB_IPFORWARD_ROW2 have fixed ABI offsets.
    [StructLayout(LayoutKind.Explicit, Size = 28)]
    private struct NativeSocketAddress
    {
        [FieldOffset(0)] public ushort Family;
        [FieldOffset(4)] public uint Ipv4;
        [FieldOffset(8)] public ulong Ipv6First;
        [FieldOffset(16)] public ulong Ipv6Second;
        [FieldOffset(24)] public uint ScopeId;

        public static NativeSocketAddress From(IPAddress address)
        {
            var bytes = address.GetAddressBytes();
            return address.AddressFamily == AddressFamily.InterNetwork
                ? new NativeSocketAddress { Family = (ushort)AddressFamily.InterNetwork, Ipv4 = BitConverter.ToUInt32(bytes) }
                : new NativeSocketAddress { Family = (ushort)AddressFamily.InterNetworkV6,
                    Ipv6First = BitConverter.ToUInt64(bytes, 0), Ipv6Second = BitConverter.ToUInt64(bytes, 8),
                    ScopeId = checked((uint)address.ScopeId) };
        }

        public IPAddress? ToAddress()
        {
            if (Family == (ushort)AddressFamily.InterNetwork) { return new IPAddress(BitConverter.GetBytes(Ipv4)); }
            if (Family != (ushort)AddressFamily.InterNetworkV6) { return null; }
            var bytes = new byte[16];
            BitConverter.GetBytes(Ipv6First).CopyTo(bytes, 0);
            BitConverter.GetBytes(Ipv6Second).CopyTo(bytes, 8);
            return new IPAddress(bytes, ScopeId);
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = 104)]
    private struct NativeRouteRow
    {
        [FieldOffset(8)] public int InterfaceIndex;
        [FieldOffset(44)] public NativeSocketAddress NextHop;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SockaddrIn6
    {
        public short Family;
        public ushort Port;
        public uint FlowInfo;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] Address;
        public uint ScopeId;
    }

    private sealed record BypassRoute(IPAddress Address, int InterfaceIndex, string NextHop,
        int RouteMetric = 0, string? CreationId = null, bool Confirmed = false);
    private sealed record PersistedBypassRoute(string Address, int InterfaceIndex, string NextHop,
        int RouteMetric = 0, string? CreationId = null, bool Confirmed = false, bool Legacy = false);
    private sealed record BypassRouteJournal(int Version, PersistedBypassRoute[] Entries);
    private sealed record BypassRouteReceipt(string CreationId, string Address, int InterfaceIndex, string NextHop, int RouteMetric, string Protocol);
    private sealed record RouteCommandResult(string Address, int InterfaceIndex, string NextHop, bool Created, bool Skipped = false,
        bool Loopback = false, bool NativeLocal = false, int RouteMetric = 0, string? Protocol = null);
    private sealed record ProtectedAddressSet(IPAddress[] Addresses, IPAddress[] EndpointAddresses, bool LiteralEndpoint,
        int EndpointPort, IPAddress[] ControlPlaneAddresses);
    private sealed record FirewallRollback(int Version, FirewallProfile[] Profiles, string[] DisabledOutboundAllowRuleNames,
        string[] OwnedRuleNames, string AdapterName, string[] ProtectedAddresses, string[]? EndpointAddresses = null,
        int EndpointPort = 0, string[]? ControlPlaneAddresses = null);
    private sealed record FirewallProfile(string Name, string Enabled, string DefaultOutboundAction);
}

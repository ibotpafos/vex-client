using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

internal sealed class NetworkSafetyController
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(10);
    private static readonly string[] ControlPlaneHosts =
    [
        "vexguard.app",
        "www.vexguard.app",
    ];

    private readonly object _gate = new();
    private readonly string _firewallStatePath;
    private readonly string _routeStatePath;
    private IReadOnlyList<BypassRoute> _activeBypassRoutes = [];
    private bool _firewallArmed;

    public NetworkSafetyController(WindowsServiceOptions options)
    {
        _firewallStatePath = Path.Combine(
            options.DataDirectory,
            "firewall-rollback.json");
        _routeStatePath = Path.Combine(
            options.DataDirectory,
            "bypass-routes.json");
        _firewallArmed = File.Exists(_firewallStatePath);
        _activeBypassRoutes = LoadPersistedRoutes();
    }

    public async Task ApplyControlPlaneBypassAsync(
        string endpoint,
        CancellationToken cancellationToken)
    {
        var addresses = await ResolveProtectedAddressesAsync(
            endpoint,
            cancellationToken).ConfigureAwait(false);
        IReadOnlyList<BypassRoute> previous;
        lock (_gate)
        {
            previous = _activeBypassRoutes;
        }
        var routes = new List<BypassRoute>();
        try
        {
            foreach (var address in addresses)
            {
                var retained = previous.FirstOrDefault(route =>
                    route.Address.Equals(address));
                if (retained is not null)
                {
                    routes.Add(retained);
                    continue;
                }
                var route = await AddBypassRouteAsync(
                    address,
                    cancellationToken).ConfigureAwait(false);
                if (route is not null)
                {
                    routes.Add(route);
                    var owned = previous.Concat(routes).Distinct().ToArray();
                    lock (_gate)
                    {
                        _activeBypassRoutes = owned;
                    }
                    PersistRoutes(owned);
                }
            }
        }
        catch
        {
            try
            {
                await RemoveRoutesAsync(routes, CancellationToken.None)
                    .ConfigureAwait(false);
                lock (_gate)
                {
                    _activeBypassRoutes = previous;
                }
                PersistRoutes(previous);
            }
            catch
            {
                PersistRoutes(_activeBypassRoutes.Concat(routes));
            }
            throw;
        }

        var removed = previous.Except(routes).ToArray();
        var combined = previous.Concat(routes).Distinct().ToArray();
        lock (_gate)
        {
            _activeBypassRoutes = combined;
        }
        PersistRoutes(combined);
        await RemoveRoutesAsync(removed, CancellationToken.None)
            .ConfigureAwait(false);
        lock (_gate)
        {
            _activeBypassRoutes = routes;
        }
        PersistRoutes(routes);
    }

    public async Task RollbackAsync(CancellationToken cancellationToken)
    {
        await DisarmFirewallAsync(cancellationToken).ConfigureAwait(false);
        IReadOnlyList<BypassRoute> routes;
        lock (_gate)
        {
            routes = _activeBypassRoutes;
        }

        await RemoveRoutesAsync(routes, cancellationToken).ConfigureAwait(false);
        lock (_gate)
        {
            _activeBypassRoutes = [];
        }
        PersistRoutes([]);
    }

    public VpnTunnelDiagnostics Capture(
        NetworkInterface? adapter,
        string? endpoint,
        bool expectsIpv6)
    {
        if (adapter is null)
        {
            return VpnTunnelDiagnostics.Empty with
            {
                Endpoint = endpoint,
                Findings = ["tunnel_adapter_missing"],
            };
        }

        var properties = adapter.GetIPProperties();
        var ipv4 = properties.GetIPv4Properties();
        var adapterIndex = ipv4?.Index;
        var dnsServers = properties.DnsAddresses
            .Select(address => address.ToString())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var statistics = adapter.GetIPv4Statistics();
        var ipv4RouteOk = adapterIndex is not null &&
            BestInterface(IPAddress.Parse("1.1.1.1")) == adapterIndex;
        var ipv6RouteOk = !expectsIpv6 ||
            adapterIndex is not null &&
            BestInterface(IPAddress.Parse("2606:4700:4700::1111")) ==
                properties.GetIPv6Properties()?.Index;
        var endpointBypassOk = EndpointBypassesAdapter(endpoint, adapterIndex);
        var findings = new List<string>();
        if (!ipv4RouteOk)
        {
            findings.Add("ipv4_route_missing");
        }
        if (!ipv6RouteOk)
        {
            findings.Add("ipv6_route_missing");
        }
        if (dnsServers.Length == 0)
        {
            findings.Add("dns_missing");
        }
        if (!endpointBypassOk)
        {
            findings.Add("endpoint_bypass_missing");
        }

        return new VpnTunnelDiagnostics(
            adapter.Name,
            adapterIndex,
            endpoint,
            statistics.BytesReceived,
            statistics.BytesSent,
            LatestHandshakeAt: null,
            ipv4RouteOk,
            ipv6RouteOk,
            DnsConfigured: dnsServers.Length > 0,
            endpointBypassOk,
            LeakProtection: _firewallArmed
                ? findings.Count == 0
                    ? VpnLeakProtectionState.Armed
                    : VpnLeakProtectionState.Blocking
                : VpnLeakProtectionState.Off,
            dnsServers,
            findings);
    }

    public bool CleanupVerified()
    {
        lock (_gate)
        {
            return _activeBypassRoutes.Count == 0 &&
                !_firewallArmed &&
                !File.Exists(_routeStatePath) &&
                !File.Exists(_firewallStatePath);
        }
    }

    public async Task ArmFirewallAsync(
        string adapterName,
        string endpoint,
        CancellationToken cancellationToken)
    {
        if (_firewallArmed)
        {
            return;
        }

        var addresses = await ResolveProtectedAddressesAsync(
            endpoint,
            cancellationToken).ConfigureAwait(false);
        const string captureScript =
            "Get-NetFirewallProfile | Select-Object Name,@{Name='DefaultOutboundAction';Expression={$_.DefaultOutboundAction.ToString()}} | ConvertTo-Json -Compress";
        var rollbackJson = await RunPowerShellAsync(
            captureScript,
            [],
            cancellationToken).ConfigureAwait(false);
        Directory.CreateDirectory(Path.GetDirectoryName(_firewallStatePath)!);
        File.WriteAllText(_firewallStatePath, rollbackJson);

        const string armScript =
            "$ErrorActionPreference='Stop';$alias=$args[0];$ips=$args[1].Split(',');" +
            "Get-NetFirewallRule -Group 'VEX VPN AntiLeak' -ErrorAction SilentlyContinue | Remove-NetFirewallRule;" +
            "New-NetFirewallRule -DisplayName 'VEX VPN tunnel' -Group 'VEX VPN AntiLeak' -Direction Outbound -Action Allow -InterfaceAlias $alias -Profile Any | Out-Null;" +
            "foreach($ip in $ips){New-NetFirewallRule -DisplayName ('VEX VPN bypass '+$ip) -Group 'VEX VPN AntiLeak' -Direction Outbound -Action Allow -RemoteAddress $ip -Profile Any | Out-Null};" +
            "Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction Block";
        try
        {
            await RunPowerShellAsync(
                armScript,
                [
                    adapterName,
                    string.Join(',', addresses.Select(value => value.ToString())),
                ],
                cancellationToken).ConfigureAwait(false);
            _firewallArmed = true;
        }
        catch
        {
            _firewallArmed = true;
            await RestoreFirewallAsync(rollbackJson, CancellationToken.None)
                .ConfigureAwait(false);
            _firewallArmed = false;
            File.Delete(_firewallStatePath);
            throw;
        }
    }

    public Task DisarmFirewallOnlyAsync(
        CancellationToken cancellationToken) =>
        DisarmFirewallAsync(cancellationToken);

    private async Task DisarmFirewallAsync(
        CancellationToken cancellationToken)
    {
        var rollbackJson = File.Exists(_firewallStatePath)
            ? File.ReadAllText(_firewallStatePath)
            : null;
        if (rollbackJson is null)
        {
            _firewallArmed = false;
            return;
        }

        await RestoreFirewallAsync(rollbackJson, cancellationToken)
            .ConfigureAwait(false);
        _firewallArmed = false;
        File.Delete(_firewallStatePath);
    }

    private static async Task RestoreFirewallAsync(
        string rollbackJson,
        CancellationToken cancellationToken)
    {
        const string script =
            "$ErrorActionPreference='Stop';" +
            "Get-NetFirewallRule -Group 'VEX VPN AntiLeak' -ErrorAction SilentlyContinue | Remove-NetFirewallRule;" +
            "$profiles=ConvertFrom-Json $args[0];foreach($profile in @($profiles)){" +
            "Set-NetFirewallProfile -Profile $profile.Name -DefaultOutboundAction $profile.DefaultOutboundAction};" +
            "$actual=Get-NetFirewallProfile;foreach($profile in @($profiles)){" +
            "$value=($actual|Where-Object Name -eq $profile.Name).DefaultOutboundAction.ToString();" +
            "if($value -ne $profile.DefaultOutboundAction.ToString()){throw 'firewall_profile_restore_failed'}};" +
            "if(@(Get-NetFirewallRule -Group 'VEX VPN AntiLeak' -ErrorAction SilentlyContinue).Count -ne 0){throw 'firewall_group_cleanup_failed'};" +
            "'ok'";
        var result = await RunPowerShellAsync(
            script,
            [rollbackJson],
            cancellationToken).ConfigureAwait(false);
        if (!string.Equals(result, "ok", StringComparison.Ordinal))
        {
            throw new VpnTunnelException("firewall_restore_unverified");
        }
    }

    private IReadOnlyList<BypassRoute> LoadPersistedRoutes()
    {
        try
        {
            var entries = JsonSerializer.Deserialize<PersistedBypassRoute[]>(
                File.ReadAllText(_routeStatePath)) ?? [];
            return entries.Select(entry => new BypassRoute(
                    IPAddress.Parse(entry.Address),
                    entry.InterfaceIndex,
                    entry.NextHop))
                .ToArray();
        }
        catch (Exception error) when (
            error is FileNotFoundException or DirectoryNotFoundException
                or JsonException or FormatException)
        {
            return [];
        }
    }

    private void PersistRoutes(IEnumerable<BypassRoute> routes)
    {
        var entries = routes
            .Distinct()
            .Select(route => new PersistedBypassRoute(
                route.Address.ToString(),
                route.InterfaceIndex,
                route.NextHop))
            .ToArray();
        if (entries.Length == 0)
        {
            File.Delete(_routeStatePath);
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(_routeStatePath)!);
        var temporaryPath = $"{_routeStatePath}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(entries));
            File.Move(temporaryPath, _routeStatePath, overwrite: true);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    private static bool EndpointBypassesAdapter(
        string? endpoint,
        int? tunnelIndex)
    {
        if (string.IsNullOrWhiteSpace(endpoint) || tunnelIndex is null)
        {
            return false;
        }

        var host = ParseEndpointHost(endpoint);
        if (!IPAddress.TryParse(host, out var address))
        {
            try
            {
                address = Dns.GetHostAddresses(host)
                    .FirstOrDefault(candidate =>
                        candidate.AddressFamily == AddressFamily.InterNetwork);
            }
            catch (SocketException)
            {
                return false;
            }
        }

        return address is not null &&
            BestInterface(address) is int bestIndex &&
            bestIndex != tunnelIndex;
    }

    private static int? BestInterface(IPAddress address)
    {
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var bytes = address.GetAddressBytes();
            var destination = BitConverter.ToUInt32(bytes, 0);
            return GetBestInterface(destination, out var index) == 0
                ? checked((int)index)
                : null;
        }

        var socketAddress = new SockaddrIn6
        {
            Family = (short)AddressFamily.InterNetworkV6,
            Address = address.GetAddressBytes(),
        };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<SockaddrIn6>());
        try
        {
            Marshal.StructureToPtr(socketAddress, pointer, false);
            return GetBestInterfaceEx(pointer, out var index) == 0
                ? checked((int)index)
                : null;
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    private static async Task<IReadOnlyList<IPAddress>>
        ResolveProtectedAddressesAsync(
            string endpoint,
            CancellationToken cancellationToken)
    {
        var hosts = ControlPlaneHosts
            .Append(ParseEndpointHost(endpoint))
            .Where(host => !string.IsNullOrWhiteSpace(host))
            .Distinct(StringComparer.OrdinalIgnoreCase);
        var addresses = new HashSet<IPAddress>();
        foreach (var host in hosts)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (IPAddress.TryParse(host, out var parsed))
            {
                if (parsed.AddressFamily == AddressFamily.InterNetwork)
                {
                    addresses.Add(parsed);
                }
                continue;
            }

            foreach (var address in await Dns.GetHostAddressesAsync(
                         host,
                         cancellationToken).ConfigureAwait(false))
            {
                if (address.AddressFamily == AddressFamily.InterNetwork)
                {
                    addresses.Add(address);
                }
            }
        }

        return addresses.ToArray();
    }

    private static string ParseEndpointHost(string endpoint)
    {
        var value = endpoint.Trim();
        if (value.StartsWith('['))
        {
            var closing = value.IndexOf(']');
            return closing > 1 ? value[1..closing] : string.Empty;
        }

        var separator = value.LastIndexOf(':');
        return separator > 0 ? value[..separator] : value;
    }

    private static async Task<BypassRoute?> AddBypassRouteAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        const string script =
            "$ErrorActionPreference='Stop';" +
            "$ip=$args[0];" +
            "$best=Find-NetRoute -RemoteIPAddress $ip | Select-Object -First 1;" +
            "if($null -eq $best){throw 'route_not_found'};" +
            "$prefix=$ip+'/32';" +
            "$existing=Get-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue |" +
            "Where-Object {$_.InterfaceIndex -eq $best.InterfaceIndex -and $_.NextHop -eq $best.NextHop} | Select-Object -First 1;" +
            "if($null -eq $existing){New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $best.InterfaceIndex -NextHop $best.NextHop -RouteMetric 1 -PolicyStore ActiveStore | Out-Null};" +
            "[pscustomobject]@{Address=$ip;InterfaceIndex=$best.InterfaceIndex;NextHop=$best.NextHop;Created=($null -eq $existing)} | ConvertTo-Json -Compress";
        var output = await RunPowerShellAsync(
            script,
            [address.ToString()],
            cancellationToken).ConfigureAwait(false);
        var result = JsonSerializer.Deserialize<RouteCommandResult>(output) ??
            throw new VpnTunnelException("route_bypass_apply_failed");
        return result.Created
            ? new BypassRoute(
                IPAddress.Parse(result.Address),
                result.InterfaceIndex,
                result.NextHop)
            : null;
    }

    private static async Task RemoveRoutesAsync(
        IEnumerable<BypassRoute> routes,
        CancellationToken cancellationToken)
    {
        const string script =
            "$ErrorActionPreference='Stop';" +
            "$prefix=$args[0]+'/32';$idx=[int]$args[1];$hop=$args[2];" +
            "Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue |" +
            "Where-Object {$_.NextHop -eq $hop} | Remove-NetRoute -Confirm:$false -ErrorAction Stop;" +
            "$remaining=Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue |" +
            "Where-Object {$_.NextHop -eq $hop};if($null -ne $remaining){throw 'route_cleanup_failed'}";
        foreach (var route in routes.Reverse())
        {
            await RunPowerShellAsync(
                script,
                [
                    route.Address.ToString(),
                    route.InterfaceIndex.ToString(
                        System.Globalization.CultureInfo.InvariantCulture),
                    route.NextHop,
                ],
                cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<string> RunPowerShellAsync(
        string script,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (arguments.Any(argument =>
                argument.Length is 0 or > 256 ||
                argument.Any(char.IsControl)))
        {
            throw new VpnTunnelException("route_bypass_argument_invalid");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("AllSigned");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add(script);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ??
            throw new VpnTunnelException("route_bypass_launch_failed");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(CommandTimeout);
        try
        {
            var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false);
            _ = await errorTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                throw new VpnTunnelException("route_bypass_command_failed");
            }
            return output.Trim();
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested)
        {
            TryTerminate(process);
            throw new VpnTunnelException("route_bypass_timeout");
        }
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (
            error is InvalidOperationException or Win32Exception)
        {
        }
    }

    [System.Runtime.InteropServices.DllImport(
        "iphlpapi.dll",
        SetLastError = true)]
    private static extern int GetBestInterface(
        uint destinationAddress,
        out uint bestInterfaceIndex);

    [System.Runtime.InteropServices.DllImport(
        "iphlpapi.dll",
        SetLastError = true)]
    private static extern int GetBestInterfaceEx(
        IntPtr destinationAddress,
        out uint bestInterfaceIndex);

    [StructLayout(LayoutKind.Sequential)]
    private struct SockaddrIn6
    {
        public short Family;
        public ushort Port;
        public uint FlowInfo;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] Address;

        public uint ScopeId;
    }

    private sealed record BypassRoute(
        IPAddress Address,
        int InterfaceIndex,
        string NextHop);

    private sealed record PersistedBypassRoute(
        string Address,
        int InterfaceIndex,
        string NextHop);

    private sealed record RouteCommandResult(
        string Address,
        int InterfaceIndex,
        string NextHop,
        bool Created);
}

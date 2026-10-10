using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

internal sealed class NetworkSafetyController
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan FirewallVerificationLifetime = TimeSpan.FromSeconds(30);
    private readonly IReadOnlyList<string> _controlPlaneHosts;
    private readonly HashSet<IPAddress> _nativeLocalEndpointAddresses;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly string _firewallStatePath;
    private readonly string _routeStatePath;
    private IReadOnlyList<BypassRoute> _activeBypassRoutes = [];
    private bool _firewallArmed;
    private bool _firewallVerified;
    private DateTimeOffset _firewallVerifiedAt;
    private int _verificationPending;
    private readonly Dictionary<string, IPAddress[]> _controlPlaneAddressCache = new(StringComparer.OrdinalIgnoreCase);

    public NetworkSafetyController(WindowsServiceOptions options)
    {
        _controlPlaneHosts = options.ControlPlaneBypassHosts.ToArray();
        _nativeLocalEndpointAddresses = options.NativeLocalEndpointAddresses.Select(IPAddress.Parse).ToHashSet();
        _firewallStatePath = Path.Combine(options.DataDirectory, "firewall-rollback.json");
        _routeStatePath = Path.Combine(options.DataDirectory, "bypass-routes.json");
        // A journal indicates possible ownership, not proof that protection works.
        _firewallArmed = File.Exists(_firewallStatePath);
        _activeBypassRoutes = LoadPersistedRoutes();
    }

    public async Task ApplyControlPlaneBypassAsync(string endpoint, CancellationToken cancellationToken)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var resolved = await ResolveProtectedAddressesAsync(endpoint, cancellationToken).ConfigureAwait(false);
            var addresses = resolved.Addresses;
            var reachable = new List<IPAddress>();
            IReadOnlyList<BypassRoute> previous;
            lock (_gate) { previous = _activeBypassRoutes; }
            var owned = new List<BypassRoute>();
            var created = new List<BypassRoute>();
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
                    // Native host-local routing is already outside the tunnel.
                    // A gateway host route would redirect the local endpoint.
                    if (result.Loopback || result.NativeLocal) { continue; }
                    var route = new BypassRoute(IPAddress.Parse(result.Address), result.InterfaceIndex, result.NextHop);
                    if (result.Created)
                    {
                        created.Add(route);
                        SetOwnedRoutes(previous.Concat(created));
                        if (!await InstallBypassRouteAsync(route, cancellationToken).ConfigureAwait(false))
                        {
                            created.Remove(route);
                        }
                    }
                    if (created.Contains(route) || previous.Contains(route))
                    {
                        owned.Add(route);
                    }
                    SetOwnedRoutes(previous.Concat(created));
                }
                if (!reachable.Any(address => resolved.EndpointAddresses.Contains(address)))
                {
                    throw new VpnTunnelException("endpoint_physical_route_missing");
                }
                await RemoveRoutesAsync(previous.Except(owned), CancellationToken.None).ConfigureAwait(false);
                SetOwnedRoutes(owned);
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
                        await RefreshFirewallBypassAsync(reachable, cancellationToken).ConfigureAwait(false);
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
                    await RemoveRoutesAsync(created, CancellationToken.None).ConfigureAwait(false);
                    SetOwnedRoutes(previous);
                }
                catch { /* The journal remains available for the next cleanup. */ }
                throw;
            }
        }
        finally { _operationGate.Release(); }
    }

    public async Task RollbackAsync(CancellationToken cancellationToken)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await DisarmFirewallCoreAsync(cancellationToken).ConfigureAwait(false);
            IReadOnlyList<BypassRoute> routes;
            lock (_gate) { routes = _activeBypassRoutes; }
            await RemoveRoutesAsync(routes, cancellationToken).ConfigureAwait(false);
            SetOwnedRoutes([]);
        }
        finally { _operationGate.Release(); }
    }

    public VpnTunnelDiagnostics Capture(
        NetworkInterface? adapter,
        string? endpoint,
        bool expectsIpv6,
        IReadOnlyList<string>? allowedIps = null,
        IReadOnlyList<string>? expectedDns = null)
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
        var endpointBypassOk = EndpointBypassesAdapter(endpoint, ipv4Index, ipv6Index);
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

    public async Task ArmFirewallAsync(string adapterName, string endpoint, CancellationToken cancellationToken)
    {
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var addresses = (await ResolveProtectedAddressesAsync(endpoint, cancellationToken).ConfigureAwait(false)).Addresses;
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
                    await RefreshFirewallBypassAsync(addresses, cancellationToken, adapterName).ConfigureAwait(false);
                    return;
                }
            }
            var prefix = $"VEX.AntiLeak.{Guid.NewGuid():N}.";
            var names = new[] { prefix + "Tunnel", prefix + "Protected", prefix + "Dhcp4", prefix + "Dhcp6", prefix + "Neighbor" };
            const string captureScript = """
                $ErrorActionPreference='Stop'
                $profiles=@(Get-NetFirewallProfile -PolicyStore PersistentStore | Select-Object Name,@{Name='Enabled';Expression={$_.Enabled.ToString()}},@{Name='DefaultOutboundAction';Expression={$_.DefaultOutboundAction.ToString()}})
                $rules=@(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Direction -eq 'Outbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True'} | Select-Object -ExpandProperty Name)
                $ownedNames=ConvertFrom-Json $args[0];$protectedAddresses=ConvertFrom-Json $args[2]
                [pscustomobject]@{Version=2;Profiles=$profiles;DisabledOutboundAllowRuleNames=$rules;OwnedRuleNames=@($ownedNames);AdapterName=$args[1];ProtectedAddresses=@($protectedAddresses)} | ConvertTo-Json -Compress -Depth 5
                """;
            var rollbackJson = await RunPowerShellAsync(captureScript,
                [JsonSerializer.Serialize(names), adapterName, JsonSerializer.Serialize(addresses.Select(address => address.ToString()))], cancellationToken).ConfigureAwait(false);
            var rollback = ParseFirewallRollback(rollbackJson);
            // The complete ownership/restore journal is durable before any mutation.
            WriteAtomic(_firewallStatePath, rollbackJson);
            SetFirewallStatus(armed: true, verified: false);
            try
            {
                const string armScript = """
                    $ErrorActionPreference='Stop'
                    $state=ConvertFrom-Json $args[0];$ips=ConvertFrom-Json $args[1];$names=@($state.OwnedRuleNames)
                    Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -cin @($state.DisabledOutboundAllowRuleNames)} | Disable-NetFirewallRule | Out-Null
                    New-NetFirewallRule -Name $names[0] -DisplayName 'VEX VPN tunnel' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -InterfaceAlias $state.AdapterName -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[1] -DisplayName 'VEX VPN protected endpoints' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -RemoteAddress $ips -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[2] -DisplayName 'VEX VPN DHCPv4' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol UDP -LocalPort 68 -RemotePort 67 -Program ($env:SystemRoot+'\System32\svchost.exe') -Service Dhcp -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[3] -DisplayName 'VEX VPN DHCPv6' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol UDP -LocalPort 546 -RemotePort 547 -Program ($env:SystemRoot+'\System32\svchost.exe') -Service Dhcp -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    New-NetFirewallRule -Name $names[4] -DisplayName 'VEX VPN IPv6 neighbors' -Group 'VEX VPN AntiLeak' -PolicyStore PersistentStore -Direction Outbound -Action Allow -Protocol ICMPv6 -IcmpType 133,135,136 -RemoteAddress 'fe80::/10','ff02::/16' -InterfaceType Wired,Wireless -Profile Any | Out-Null
                    Set-NetFirewallProfile -Profile Domain,Private,Public -PolicyStore PersistentStore -Enabled True -DefaultOutboundAction Block
                    """;
                await RunPowerShellAsync(armScript, [rollbackJson, JsonSerializer.Serialize(addresses.Select(value => value.ToString()))], cancellationToken).ConfigureAwait(false);
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

    private async Task RefreshFirewallBypassAsync(IReadOnlyList<IPAddress> addresses, CancellationToken cancellationToken, string? adapterName = null)
    {
        SetFirewallStatus(armed: true, verified: false);
        var state = ParseFirewallRollback(File.ReadAllText(_firewallStatePath));
        state = state with
        {
            AdapterName = adapterName ?? state.AdapterName,
            ProtectedAddresses = addresses.Select(address => address.ToString()).ToArray(),
        };
        WriteAtomic(_firewallStatePath, JsonSerializer.Serialize(state));
        const string script = """
            $ErrorActionPreference='Stop';$name=$args[0];$ips=ConvertFrom-Json $args[1];$tunnelName=$args[2];$alias=$args[3]
            $rule=Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -ceq $name}
            if(@($rule).Count -ne 1){throw 'firewall_owned_rule_missing'}
            $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $ips | Out-Null
            Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Name -ceq $tunnelName} | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias $alias | Out-Null
            """;
        await RunPowerShellAsync(script, [state.OwnedRuleNames[1], JsonSerializer.Serialize(addresses.Select(address => address.ToString())), state.OwnedRuleNames[0], state.AdapterName], cancellationToken).ConfigureAwait(false);
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
            $rules=@(Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object {$_.Direction -eq 'Outbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True'})
            if(@($rules | Where-Object {$_.Name -cnotin $names}).Count -ne 0){throw 'firewall_external_allow_active'}
            foreach($name in $names){if(@($rules | Where-Object {$_.Name -ceq $name}).Count -ne 1){throw 'firewall_owned_allow_missing'}}
            $tunnel=$rules | Where-Object {$_.Name -ceq $names[0]}
            if(!(Same-Set @($tunnel | Get-NetFirewallInterfaceFilter | Select-Object -ExpandProperty InterfaceAlias) @($state.AdapterName))){throw 'firewall_tunnel_interface_unverified'}
            $protected=$rules | Where-Object {$_.Name -ceq $names[1]}
            $remote=@($protected | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress | ForEach-Object {[System.Net.IPAddress]::Parse($_).ToString()})
            if(!(Same-Set $remote @($state.ProtectedAddresses))){throw 'firewall_protected_addresses_unverified'}
            foreach($i in 1..4){
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
            var result = await RunPowerShellAsync(script, [JsonSerializer.Serialize(state)], cancellationToken).ConfigureAwait(false);
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
        if (state is null || state.Version != 2 || state.Profiles is not { Length: 3 } || state.OwnedRuleNames is not { Length: 5 } ||
            state.DisabledOutboundAllowRuleNames is null || state.ProtectedAddresses is not { Length: > 0 } || string.IsNullOrWhiteSpace(state.AdapterName) ||
            state.OwnedRuleNames.Any(name => !name.StartsWith("VEX.AntiLeak.", StringComparison.Ordinal)))
        {
            throw new VpnTunnelException("firewall_rollback_state_invalid");
        }
        return state;
    }

    private static async Task RestoreFirewallAsync(string rollbackJson, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$state=ConvertFrom-Json $args[0]
            if($state.Version -eq 2){
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
        var result = await RunPowerShellAsync(script, [rollbackJson], cancellationToken).ConfigureAwait(false);
        if (result != "ok") { throw new VpnTunnelException("firewall_restore_unverified"); }
    }

    private IReadOnlyList<BypassRoute> LoadPersistedRoutes()
    {
        try
        {
            return (JsonSerializer.Deserialize<PersistedBypassRoute[]>(File.ReadAllText(_routeStatePath)) ?? [])
                .Select(entry => new BypassRoute(IPAddress.Parse(entry.Address), entry.InterfaceIndex, entry.NextHop)).ToArray();
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException or JsonException or FormatException)
        {
            return [];
        }
    }

    private void SetOwnedRoutes(IEnumerable<BypassRoute> routes)
    {
        var owned = routes.Distinct().ToArray();
        PersistRoutes(owned);
        lock (_gate) { _activeBypassRoutes = owned; }
    }

    private void PersistRoutes(IEnumerable<BypassRoute> routes)
    {
        var entries = routes.Distinct().Select(route => new PersistedBypassRoute(route.Address.ToString(), route.InterfaceIndex, route.NextHop)).ToArray();
        if (entries.Length == 0) { File.Delete(_routeStatePath); return; }
        WriteAtomic(_routeStatePath, JsonSerializer.Serialize(entries));
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

    private static bool EndpointBypassesAdapter(string? endpoint, int? ipv4TunnelIndex, int? ipv6TunnelIndex)
    {
        if (string.IsNullOrWhiteSpace(endpoint)) { return false; }
        try
        {
            var host = ParseEndpointHost(endpoint);
            var addresses = IPAddress.TryParse(host, out var address) ? [address] : Dns.GetHostAddresses(host);
            var routes = addresses.Select(candidate => (Address: candidate, Index: BestInterface(candidate)))
                .Where(route => route.Index is not null).ToArray();
            return routes.Length > 0 && routes.All(route =>
                route.Index != (route.Address.AddressFamily == AddressFamily.InterNetwork ? ipv4TunnelIndex : ipv6TunnelIndex));
        }
        catch (Exception error) when (error is SocketException or VpnTunnelException or ArgumentException) { return false; }
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

    private async Task<ProtectedAddressSet> ResolveProtectedAddressesAsync(string endpoint, CancellationToken cancellationToken)
    {
        var endpointHost = ParseEndpointHost(endpoint);
        var addresses = new HashSet<IPAddress>();
        var endpointAddresses = new HashSet<IPAddress>();
        foreach (var host in _controlPlaneHosts.Prepend(endpointHost).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            IPAddress[] resolved;
            try
            {
                resolved = IPAddress.TryParse(host, out var parsed) ? [parsed] : await Dns.GetHostAddressesAsync(host, cancellationToken).ConfigureAwait(false);
                if (host != endpointHost) { _controlPlaneAddressCache[host] = resolved; }
            }
            catch (SocketException) when (host != endpointHost && _controlPlaneAddressCache.ContainsKey(host))
            {
                // During Wi-Fi recovery the protected resolver may be inside the
                // unavailable tunnel. Keep the last resolved control-plane hosts.
                resolved = _controlPlaneAddressCache[host];
            }
            if (host == endpointHost && resolved.Length == 0) { throw new VpnTunnelException("endpoint_resolution_failed"); }
            foreach (var address in resolved)
            {
                if (address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
                {
                    addresses.Add(address);
                    if (host == endpointHost) { endpointAddresses.Add(address); }
                }
            }
        }
        if (addresses.Count == 0) { throw new VpnTunnelException("endpoint_resolution_failed"); }
        return new ProtectedAddressSet(addresses.ToArray(), endpointAddresses.ToArray(),
            IPAddress.TryParse(endpointHost, out _));
    }

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

    private static async Task<RouteCommandResult> FindBypassRouteAsync(IPAddress address, bool allowMissingPhysical,
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
            [pscustomobject]@{Address=$ip;InterfaceIndex=$best.InterfaceIndex;NextHop=$best.NextHop;Created=($null -eq $existing)} | ConvertTo-Json -Compress
            """;
        var output = await RunPowerShellAsync(script,
            [address.ToString(), address.AddressFamily == AddressFamily.InterNetwork ? "IPv4" : "IPv6", address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128", allowMissingPhysical.ToString(), nativeLocalEndpoint.ToString()], cancellationToken).ConfigureAwait(false);
        return JsonSerializer.Deserialize<RouteCommandResult>(output) ?? throw new VpnTunnelException("route_bypass_apply_failed");
    }

    private static async Task<bool> InstallBypassRouteAsync(BypassRoute route, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$prefix=$args[0]+'/'+$args[3];$idx=[int]$args[1];$hop=$args[2]
            $existing=Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $hop} | Select-Object -First 1
            if($null -ne $existing){'existing';return}
            New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -NextHop $hop -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
            'created'
            """;
        var result = await RunPowerShellAsync(script,
            [route.Address.ToString(), route.InterfaceIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), route.NextHop,
                route.Address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128"], cancellationToken).ConfigureAwait(false);
        return result == "created";
    }

    private static async Task RemoveRoutesAsync(IEnumerable<BypassRoute> routes, CancellationToken cancellationToken)
    {
        const string script = """
            $ErrorActionPreference='Stop';$prefix=$args[0]+'/'+$args[3];$idx=[int]$args[1];$hop=$args[2]
            Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $hop} | Remove-NetRoute -Confirm:$false -ErrorAction Stop
            $remaining=Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $hop}
            if($null -ne $remaining){throw 'route_cleanup_failed'}
            """;
        foreach (var route in routes.Reverse())
        {
            await RunPowerShellAsync(script,
                [route.Address.ToString(), route.InterfaceIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), route.NextHop, route.Address.AddressFamily == AddressFamily.InterNetwork ? "32" : "128"], cancellationToken).ConfigureAwait(false);
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

    [StructLayout(LayoutKind.Sequential)]
    private struct SockaddrIn6
    {
        public short Family;
        public ushort Port;
        public uint FlowInfo;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] Address;
        public uint ScopeId;
    }

    private sealed record BypassRoute(IPAddress Address, int InterfaceIndex, string NextHop);
    private sealed record PersistedBypassRoute(string Address, int InterfaceIndex, string NextHop);
    private sealed record RouteCommandResult(string Address, int InterfaceIndex, string NextHop, bool Created, bool Skipped = false,
        bool Loopback = false, bool NativeLocal = false);
    private sealed record ProtectedAddressSet(IPAddress[] Addresses, IPAddress[] EndpointAddresses, bool LiteralEndpoint);
    private sealed record FirewallRollback(int Version, FirewallProfile[] Profiles, string[] DisabledOutboundAllowRuleNames, string[] OwnedRuleNames, string AdapterName, string[] ProtectedAddresses);
    private sealed record FirewallProfile(string Name, string Enabled, string DefaultOutboundAction);
}

using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.VpnAcceptance;

// Opt-in only on a fresh disposable host. The peer has no Internet forwarding:
// DNS/HTTPS below prove encrypted tunnel traffic, while the public HTTPS probe
// proves only the explicitly admitted physical control-plane exception.
internal static class FullTunnelAcceptance
{
    private const string ControlHost = "vexguard.app";

    internal static async Task RunAsync(string directory, string runtimeDirectory,
        Dictionary<string, object?> result, CancellationToken token)
    {
        foreach (var flag in new[] { "full_tunnel_dns_verified", "full_tunnel_https_verified",
            "full_control_plane_https_bypass_verified", "full_physical_tcp_prebaseline_verified",
            "full_physical_tcp_blocked", "full_physical_tcp_restored", "full_physical_dns_supported",
            "full_physical_dns_blocked", "full_physical_dns_restored", "full_vendor_demand_start_verified",
            "full_vendor_routes_verified", "full_physical_route_retained_verified", "full_anti_leak_enabled",
            "full_controller_death_watchdog_verified", "full_owned_cleanup_verified" }) result[flag] = false;
        Require(Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" && OperatingSystem.IsWindows(),
            "fixture_full_requires_disposable_host");
        await VerifyControllerDeathWatchdogAsync(directory, token);
        result["full_controller_death_watchdog_verified"] = true;
        var manifest = JsonSerializer.Deserialize<Program.Manifest>(
            await File.ReadAllTextAsync(Path.Combine(directory, "manifest.json"), token))
            ?? throw new Program.FixtureException("fixture_full_manifest_missing");
        var source = IPEndPoint.Parse(manifest.Endpoint).Address;
        var nic = NetworkInterface.GetAllNetworkInterfaces().Single(adapter => adapter.OperationalStatus == OperationalStatus.Up &&
            adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback && !adapter.Name.Equals("vex", StringComparison.OrdinalIgnoreCase) &&
            adapter.GetIPProperties().UnicastAddresses.Any(address => address.Address.Equals(source)));
        var index = nic.GetIPProperties().GetIPv4Properties()?.Index ?? 0;
        Require(index > 0 && source.AddressFamily == AddressFamily.InterNetwork, "fixture_full_physical_interface_missing");
        using var dnsDeadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        dnsDeadline.CancelAfter(TimeSpan.FromSeconds(8));
        var controlAddresses = (await Dns.GetHostAddressesAsync(ControlHost, dnsDeadline.Token))
            .Where(address => address.AddressFamily == AddressFamily.InterNetwork).ToArray();
        Require(controlAddresses.Length > 0, "fixture_full_control_ipv4_missing");
        var outside = new[] { IPAddress.Parse("1.1.1.1"), IPAddress.Parse("8.8.8.8") }
            .First(address => !controlAddresses.Contains(address));
        result["stage"] = "full-physical-baseline";
        VerifyPhysicalRoute(source, index, outside);
        Require(await TcpReachableAsync(source, index, outside, TimeSpan.FromSeconds(8), token),
            "fixture_full_physical_tcp_baseline_unavailable");
        result["full_physical_tcp_prebaseline_verified"] = true;
        await ProbeControlHttpsAsync(source, index, controlAddresses[0], token);
        var physicalDns = nic.GetIPProperties().DnsAddresses.FirstOrDefault(address =>
            address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address) &&
            !address.Equals(source) && !controlAddresses.Contains(address));
        var dnsSupported = physicalDns is not null && await PhysicalDnsReachableAsync(source, index, physicalDns,
            TimeSpan.FromSeconds(3), token);
        result["full_physical_dns_supported"] = dnsSupported;
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var signer = new VpnProfileSigningKey("ci-fixture", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()));
        await ScmIpcFixture.RunFullControllerAsync(directory, runtimeDirectory, manifest, signer, result,
            async (transport, options, phaseToken) =>
            {
                // Issue only after the private service is ready: startup time
                // must not consume this independent maximum sixty-second lease.
                var signed = Program.CreateSignedProfile(manifest, TimeSpan.FromSeconds(60), key, fullTunnel: true);
                Require(signed.Profile.TunnelConfig.Contains("0.0.0.0/1", StringComparison.Ordinal) &&
                    signed.Profile.TunnelConfig.Contains("128.0.0.0/1", StringComparison.Ordinal) &&
                    !signed.Profile.TunnelConfig.Contains("0.0.0.0/0", StringComparison.Ordinal),
                    "fixture_full_vendor_routes_not_translated");
                using var lease = CancellationTokenSource.CreateLinkedTokenSource(phaseToken);
                lease.CancelAfter(signed.Profile.ExpiresAt - DateTimeOffset.UtcNow - TimeSpan.FromSeconds(2));
                var leaseToken = lease.Token;
                result["stage"] = "full-signed-connect";
                var connected = await transport.SendAsync(VpnServiceRequest.TrustedConnect(RequestId(), signed.Authorization,
                    manifest.ClientPrivateKey, antiLeakEnabled: true), leaseToken);
                RequireProtected(connected);
                var before = connected.Snapshot.Diagnostics!;
                result["full_anti_leak_enabled"] = true;
                Require(before.AdapterIndex is > 0 && before.LatestHandshakeAt >= DateTimeOffset.UtcNow.AddMinutes(-1),
                    "fixture_full_handshake_missing");
                result["full_fresh_handshake_utc"] = before.LatestHandshakeAt;
                ScmIpcFixture.AssertVendorDemandStart();
                result["full_vendor_demand_start_verified"] = true;
                var vendorConfig = await File.ReadAllTextAsync(Path.Combine(options.DataDirectory, "Private", "vex.conf"), leaseToken);
                Require(vendorConfig.Contains("0.0.0.0/1", StringComparison.Ordinal) &&
                    vendorConfig.Contains("128.0.0.0/1", StringComparison.Ordinal) &&
                    !vendorConfig.Contains("0.0.0.0/0", StringComparison.Ordinal), "fixture_full_actual_vendor_routes_invalid");
                result["full_vendor_routes_verified"] = true;
                result["stage"] = "full-tunnel-traffic";
                result["full_dns_query_attempts"] = await Program.ProbeTunnelDnsAsync(before.AdapterIndex!.Value, leaseToken);
                result["full_tunnel_dns_verified"] = true;
                await Program.ProbeTunnelHttpsAsync(before.AdapterIndex.Value, directory, leaseToken);
                result["full_tunnel_https_verified"] = true;
                result["stage"] = "full-physical-control-bypass";
                // Use only the runtime's exact signed-lease-qualified DNS cache,
                // so DNS rotation between baseline and connect cannot select an
                // unrelated address or accidentally fall back into the tunnel.
                var snapshot = JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(await File.ReadAllTextAsync(
                    Path.Combine(options.DataDirectory, "control-plane-address-cache.json"), leaseToken));
                var cache = new VpnControlPlaneAddressCache();
                Require(cache.Restore(snapshot, options.ControlPlaneBypassHosts, DateTimeOffset.UtcNow),
                    "fixture_full_control_cache_invalid");
                var admitted = cache.Get(manifest.Endpoint, manifest.ServerPublicKey, options.ControlPlaneBypassHosts,
                    signed.Profile.ExpiresAt, DateTimeOffset.UtcNow);
                Require(!admitted.Values.SelectMany(values => values).Contains(outside) && !outside.Equals(source),
                    "fixture_full_deny_target_is_admitted");
                if (dnsSupported)
                    Require(!admitted.Values.SelectMany(values => values).Contains(physicalDns!),
                        "fixture_full_dns_deny_target_is_admitted");
                Require(admitted.TryGetValue(ControlHost, out var addresses), "fixture_full_control_host_not_admitted");
                var control = addresses!.FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork);
                Require(control is not null && !control.Equals(outside), "fixture_full_control_address_invalid");
                await ProbeControlHttpsAsync(source, index, control!, leaseToken);
                result["full_control_plane_https_bypass_verified"] = true;
                result["stage"] = "full-physical-deny";
                VerifyPhysicalRoute(source, index, outside);
                result["full_physical_route_retained_verified"] = true;
                RequireProtected(await transport.SendAsync(VpnServiceRequest.Diagnostics(RequestId()), leaseToken));
                Require(!await TcpReachableAsync(source, index, outside, TimeSpan.FromSeconds(3), leaseToken),
                    "fixture_full_physical_tcp_leaked");
                result["full_physical_tcp_blocked"] = true;
                if (dnsSupported)
                {
                    Require(!await PhysicalDnsReachableAsync(source, index, physicalDns!, TimeSpan.FromSeconds(3), leaseToken),
                        "fixture_full_physical_dns_leaked");
                    result["full_physical_dns_blocked"] = true;
                }
                var after = await transport.SendAsync(VpnServiceRequest.Diagnostics(RequestId()), leaseToken);
                RequireProtected(after);
                Require(after.Snapshot.Diagnostics!.RxBytes > before.RxBytes && after.Snapshot.Diagnostics.TxBytes > before.TxBytes,
                    "fixture_full_encrypted_counters_not_increasing");
                result["full_uapi_rx_delta"] = after.Snapshot.Diagnostics.RxBytes - before.RxBytes;
                result["full_uapi_tx_delta"] = after.Snapshot.Diagnostics.TxBytes - before.TxBytes;
                result["stage"] = "full-disconnect-restoration";
                // Caller/lease cancellation cannot cancel cleanup. The SCM
                // controller also stops independently in the enclosing finally.
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(40));
                var disconnected = await transport.SendAsync(VpnServiceRequest.Disconnect(RequestId()), cleanup.Token);
                Require(disconnected.Success && disconnected.Snapshot.Phase == VpnConnectionPhase.Disconnected,
                    "fixture_full_disconnect_failed");
                Require(await TcpReachableAsync(source, index, outside, TimeSpan.FromSeconds(8), cleanup.Token),
                    "fixture_full_physical_tcp_not_restored");
                if (dnsSupported)
                {
                    Require(await PhysicalDnsReachableAsync(source, index, physicalDns!, TimeSpan.FromSeconds(3), cleanup.Token),
                        "fixture_full_physical_dns_not_restored");
                    result["full_physical_dns_restored"] = true;
                }
                result["full_physical_tcp_restored"] = true;
            }, token);
    }

    private static void RequireProtected(VpnServiceResponse response) => Require(response.Success &&
        response.Snapshot.Phase == VpnConnectionPhase.Connected &&
        response.Snapshot.Diagnostics is { IsUsable: true, LeakProtection: VpnLeakProtectionState.Armed },
        "fixture_full_protection_not_usable");

    private static Socket PhysicalSocket(IPAddress source, int index, SocketType type, ProtocolType protocol)
    {
        var socket = new Socket(AddressFamily.InterNetwork, type, protocol);
        try
        {
            socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(index));
            socket.Bind(new IPEndPoint(source, 0));
            return socket;
        }
        catch { socket.Dispose(); throw; }
    }

    private static void VerifyPhysicalRoute(IPAddress source, int index, IPAddress destination)
    {
        // Query the production ABI with the same explicit interface constraint
        // as the probe socket. A missing physical route must not pass as an
        // AntiLeak block merely because the full tunnel cannot forward it.
        var controller = typeof(Vex.Windows.Service.Runtime.AmneziaServiceTunnelRuntime).Assembly.GetType(
            "Vex.Windows.Service.Runtime.NetworkSafetyController")!;
        var socket = controller.GetNestedType("NativeSocketAddress", BindingFlags.NonPublic)!;
        var row = controller.GetNestedType("NativeRouteRow", BindingFlags.NonPublic)!;
        var encode = socket.GetMethod("From", BindingFlags.Public | BindingFlags.Static)!;
        var decode = socket.GetMethod("ToAddress", BindingFlags.Public | BindingFlags.Instance)!;
        var getRoute = controller.GetMethod("GetBestRoute2", BindingFlags.NonPublic | BindingFlags.Static)!;
        object?[] arguments = [IntPtr.Zero, checked((uint)index), IntPtr.Zero, encode.Invoke(null, [destination]), 0u,
            Activator.CreateInstance(row), Activator.CreateInstance(socket)];
        Require(getRoute.Invoke(null, arguments) is uint status && status == 0 &&
            row.GetField("InterfaceIndex")!.GetValue(arguments[5]) is int actual && actual == index &&
            decode.Invoke(arguments[6], null) is IPAddress selected && selected.Equals(source),
            "fixture_full_physical_route_missing");
    }

    private static async Task<bool> TcpReachableAsync(IPAddress source, int index, IPAddress destination,
        TimeSpan budget, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(budget);
        using var socket = PhysicalSocket(source, index, SocketType.Stream, ProtocolType.Tcp);
        try { await socket.ConnectAsync(new IPEndPoint(destination, 443), deadline.Token); return true; }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return false; }
        catch (SocketException error) when (error.SocketErrorCode is SocketError.AccessDenied or SocketError.TimedOut or
            SocketError.ConnectionRefused or SocketError.HostUnreachable or SocketError.NetworkUnreachable) { return false; }
    }

    private static async Task ProbeControlHttpsAsync(IPAddress source, int index, IPAddress destination, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(8));
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false, AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(5),
            ConnectCallback = async (context, cancellation) =>
            {
                Require(context.DnsEndPoint.Host.Equals(ControlHost, StringComparison.OrdinalIgnoreCase) &&
                    context.DnsEndPoint.Port == 443, "fixture_full_control_request_scope_invalid");
                var socket = PhysicalSocket(source, index, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(destination, 443), cancellation);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch { socket.Dispose(); throw; }
            },
        };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://" + ControlHost + "/");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        Require((int)response.StatusCode is >= 100 and <= 599, "fixture_full_control_https_invalid");
        // Normal public TLS/hostname validation is mandatory. No authorization,
        // cookie, redirect, response body or production account enters evidence.
    }

    private static async Task<bool> PhysicalDnsReachableAsync(IPAddress source, int index, IPAddress destination,
        TimeSpan budget, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(budget);
        using var socket = PhysicalSocket(source, index, SocketType.Dgram, ProtocolType.Udp);
        var packet = new List<byte>([0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        var id = RandomNumberGenerator.GetBytes(2); packet[0] = id[0]; packet[1] = id[1];
        foreach (var label in ControlHost.Split('.')) { packet.Add((byte)label.Length); packet.AddRange(Encoding.ASCII.GetBytes(label)); }
        packet.AddRange([0, 0, 1, 0, 1]);
        try
        {
            await socket.ConnectAsync(new IPEndPoint(destination, 53), deadline.Token);
            await socket.SendAsync(packet.ToArray(), SocketFlags.None, deadline.Token);
            var response = new byte[1232];
            var count = await socket.ReceiveAsync(response, SocketFlags.None, deadline.Token);
            Require(count >= 12 && response[0] == id[0] && response[1] == id[1] && (response[2] & 0x80) != 0 &&
                BinaryPrimitives.ReadUInt16BigEndian(response.AsSpan(4)) == 1, "fixture_full_physical_dns_response_invalid");
            return true;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return false; }
        catch (SocketException error) when (error.SocketErrorCode is SocketError.AccessDenied or SocketError.TimedOut or
            SocketError.ConnectionRefused or SocketError.HostUnreachable or SocketError.NetworkUnreachable) { return false; }
    }

    private static async Task VerifyControllerDeathWatchdogAsync(string directory, CancellationToken token)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--watchdog-probe"); start.ArgumentList.Add(directory);
        using var probe = Process.Start(start) ?? throw new Program.FixtureException("fixture_full_watchdog_probe_missing");
        using var lifetime = new CancellationTokenSource();
        var monitor = ScmIpcFixture.ObserveControllerDeathAsync(probe, lifetime);
        try
        {
            var ready = Path.Combine(directory, "watchdog-probe-ready");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(TimeSpan.FromSeconds(10));
            while (!File.Exists(ready))
            {
                Require(!probe.HasExited, "fixture_full_watchdog_probe_exited");
                await Task.Delay(50, deadline.Token);
            }
            probe.Kill(); // Exact owned child only, never the SCM controller.
            await probe.WaitForExitAsync(deadline.Token);
            await monitor.WaitAsync(TimeSpan.FromSeconds(3), token);
            Require(lifetime.IsCancellationRequested, "fixture_full_controller_death_not_observed");
            File.Delete(ready);
        }
        finally
        {
            lifetime.Cancel();
            await monitor;
            if (!probe.HasExited)
            {
                probe.Kill();
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await probe.WaitForExitAsync(cleanup.Token);
            }
        }
    }

    internal static async Task<int> RunWatchdogProbeAsync(string directory)
    {
        Require(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted", "fixture_full_watchdog_host_invalid");
        directory = Path.GetFullPath(directory);
        var root = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "missing")
            .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Require(directory.StartsWith(root, StringComparison.OrdinalIgnoreCase) &&
            Guid.TryParseExact(File.ReadAllText(Path.Combine(directory, "owned-fixture")).Trim(), "N", out _) &&
            Path.GetFullPath(Environment.ProcessPath!).StartsWith(directory + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase), "fixture_full_watchdog_owner_invalid");
        await File.WriteAllTextAsync(Path.Combine(directory, "watchdog-probe-ready"), "ready");
        await Task.Delay(TimeSpan.FromSeconds(30));
        return 0;
    }

    private static string RequestId() => Guid.NewGuid().ToString("N");
    private static void Require(bool condition, string code)
    {
        if (!condition) throw new Program.FixtureException(code);
    }
}

using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Service;
using Vex.Windows.Service.Runtime;

// This executable is deliberately restricted to a fresh GitHub-hosted Windows
// runner. It invokes the real VEX verifier/materializer/runtime with a temporary
// trust anchor and an isolated AWG peer; no production API or credentials exist.
internal static class Program
{
    private const string ClientIp = "10.253.253.2";
    private const string ServerIp = "10.253.253.1";
    private const string Host = "fixture.vex.invalid";

    public static async Task<int> Main(string[] args)
    {
        if (args.Length != 4 || args[0] != "--disposable-runner") { return 2; }
        var directory = Path.GetFullPath(args[1]);
        var runtimeDirectory = Path.GetFullPath(args[2]);
        var resultPath = Path.GetFullPath(args[3]);
        var result = new Dictionary<string, object?>
        {
            ["schema"] = "vex.windows-vpn-acceptance.v1",
            ["started_at_utc"] = DateTimeOffset.UtcNow,
            ["runtime_version"] = "amneziawg-windows-client/3.1.0",
            ["peer_module"] = "amneziawg-go/v3@v3.1.20260814",
            ["anti_leak_enabled"] = false,
            ["dns_over_tunnel"] = false,
            ["https_over_tunnel"] = false,
            ["runtime_disconnect_verified"] = false,
            ["passed"] = false,
            ["stage"] = "isolation",
        };
        AmneziaServiceTunnelRuntime? runtime = null;
        var exitCode = 1;
        try
        {
            AssertIsolation(directory);
            var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(Path.Combine(directory, "manifest.json")))
                ?? throw new InvalidOperationException("fixture_manifest_missing");
            Require(manifest.Schema == "vex.windows-vpn-fixture.v1" && manifest.ClientIp == ClientIp && manifest.ServerIp == ServerIp,
                "fixture_manifest_invalid");
            var endpoint = IPEndPoint.Parse(manifest.Endpoint);
            Require(endpoint.Address.Equals(IPAddress.Loopback) && endpoint.Port > 0, "fixture_endpoint_invalid");

            var dataDirectory = Path.Combine(directory, "service-state");
            Directory.CreateDirectory(dataDirectory);
            var options = new WindowsServiceOptions(dataDirectory, runtimeDirectory,
                Path.Combine(dataDirectory, "ipc-token.bin"), Path.Combine(dataDirectory, "client-cert-sha256"),
                Path.Combine(dataDirectory, "owner-sid"), Path.Combine(directory, "amneziawg-sha256"),
                Path.Combine(directory, "wintun-sha256"), Path.Combine(directory, "unused-keyring.json"),
                Path.Combine(directory, "unused-keyring-sha256")) { ControlPlaneBypassHosts = [] };
            result["stage"] = "signed-profile-admission";
            var profile = SignedProfile(manifest, result);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(110));
            runtime = new AmneziaServiceTunnelRuntime(options);
            result["stage"] = "runtime-connect";
            var connected = await runtime.ConnectAsync(profile.LocationId, profile.TunnelConfig,
                profile.ExpiresAt, antiLeakEnabled: false, deadline.Token);
            var before = connected.Diagnostics ?? throw new InvalidOperationException("fixture_diagnostics_missing");
            Require(connected.Phase == VpnConnectionPhase.Connected && before.IsUsable && before.AdapterIndex is > 0,
                "fixture_tunnel_not_usable");
            Require(before.LeakProtection == VpnLeakProtectionState.Off && before.LatestHandshakeAt >= DateTimeOffset.UtcNow.AddMinutes(-1),
                "fixture_handshake_or_firewall_invalid");
            // The peer address must never be a local OS address. Otherwise Windows
            // could short-circuit the request without passing through the tunnel.
            Require(!NetworkInterface.GetAllNetworkInterfaces().SelectMany(nic => nic.GetIPProperties().UnicastAddresses)
                .Any(address => address.Address.ToString() == ServerIp), "fixture_peer_address_on_host");
            result["fresh_handshake_utc"] = before.LatestHandshakeAt;
            result["tunnel_adapter"] = before.AdapterName;
            result["ipv4_route_verified"] = before.Ipv4RouteOk;
            result["dns_configuration_verified"] = before.DnsConfigured;
            result["endpoint_native_loopback_bypass"] = before.EndpointBypassOk;

            result["stage"] = "tunnel-dns";
            await ProbeDnsAsync(before.AdapterIndex!.Value, deadline.Token);
            result["dns_over_tunnel"] = true;
            result["stage"] = "tunnel-https";
            await ProbeHttpsAsync(before.AdapterIndex.Value, directory, deadline.Token);
            result["https_over_tunnel"] = true;

            var after = (await runtime.GetDiagnosticsAsync(deadline.Token)).Diagnostics
                ?? throw new InvalidOperationException("fixture_diagnostics_missing");
            Require(after.IsUsable && after.RxBytes > before.RxBytes && after.TxBytes > before.TxBytes,
                "fixture_encrypted_counters_not_increasing");
            result["uapi_rx_delta"] = after.RxBytes - before.RxBytes;
            result["uapi_tx_delta"] = after.TxBytes - before.TxBytes;
            result["stage"] = "peer-traffic-confirmation";
            var peer = await ReadPeerStatusAsync(directory, deadline.Token);
            Require(peer.HandshakeUnix >= DateTimeOffset.UtcNow.AddMinutes(-1).ToUnixTimeSeconds() &&
                peer.RxBytes > 0 && peer.TxBytes > 0 && peer.DnsRequests > 0 && peer.HttpsRequests > 0,
                "fixture_peer_traffic_not_confirmed");
            result["peer_rx_bytes"] = peer.RxBytes;
            result["peer_tx_bytes"] = peer.TxBytes;
            result["peer_dns_requests"] = peer.DnsRequests;
            result["peer_https_requests"] = peer.HttpsRequests;
            exitCode = 0;
        }
        catch (Exception exception)
        {
            // Never emit arbitrary exception messages, config, manifest or UAPI.
            result["failure_type"] = exception.GetType().FullName;
            if (exception is VpnTunnelException tunnelException) { result["failure_code"] = tunnelException.Code; }
            if (exception is FixtureException fixtureException) { result["failure_code"] = fixtureException.Code; }
        }
        finally
        {
            if (runtime is not null)
            {
                try
                {
                    using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(40));
                    var disconnected = await runtime.DisconnectAsync(cleanup.Token);
                    Require(disconnected.Phase == VpnConnectionPhase.Disconnected, "fixture_disconnect_failed");
                    Require(!File.Exists(Path.Combine(directory, "service-state", "firewall-rollback.json")) &&
                        !File.Exists(Path.Combine(directory, "service-state", "bypass-routes.json")), "fixture_network_journal_not_cleaned");
                    result["runtime_disconnect_verified"] = true;
                }
                catch (Exception exception) { result["cleanup_failure_type"] = exception.GetType().FullName; exitCode = 1; }
                runtime.Dispose();
            }
            result["passed"] = exitCode == 0;
            if (exitCode == 0) { result["stage"] = "completed"; }
            result["completed_at_utc"] = DateTimeOffset.UtcNow;
            Directory.CreateDirectory(Path.GetDirectoryName(resultPath)!);
            await File.WriteAllTextAsync(resultPath, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }
        return exitCode;
    }

    private static void AssertIsolation(string directory)
    {
        Require(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
            Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows", "fixture_requires_disposable_hosted_windows");
        using var identity = WindowsIdentity.GetCurrent();
        Require(new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator), "fixture_requires_administrator");
        var runnerTemp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "missing");
        Require(directory.StartsWith(runnerTemp.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase) && Guid.TryParse(File.ReadAllText(Path.Combine(directory, "owned-fixture")).Trim(), out _),
            "fixture_owned_directory_invalid");
        Require(!ServiceController.GetServices().Any(service =>
            service.ServiceName == WindowsServiceOptions.ServiceName ||
            service.ServiceName.StartsWith("AmneziaWG", StringComparison.OrdinalIgnoreCase) ||
            service.ServiceName.StartsWith("WireGuard", StringComparison.OrdinalIgnoreCase) ||
            service.ServiceName.StartsWith("OpenVPN", StringComparison.OrdinalIgnoreCase)), "fixture_foreign_vpn_service_present");
        Require(!NetworkInterface.GetAllNetworkInterfaces().Any(nic =>
            nic.Name.Equals("vex", StringComparison.OrdinalIgnoreCase) ||
            nic.GetIPProperties().UnicastAddresses.Any(address => address.Address.ToString() is ClientIp or ServerIp)),
            "fixture_tunnel_address_already_present");
    }

    private static VpnAuthorizedProfile SignedProfile(Manifest manifest, Dictionary<string, object?> result)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var now = DateTimeOffset.UtcNow;
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schema = "vex.native-vpn-profile.v1", profile_version = 1,
            user_id = "ci-fixture-user", device_id = "ci-fixture-device",
            requested_location_id = "ci-fixture", assigned_location_id = "ci-fixture",
            routing_mode = "full", bypass_region = "", routing_policy_version = "ci-fixture-v1",
            issued_at = now, expires_at = now.AddMinutes(10),
            tunnel = new
            {
                protocol = "amneziawg", endpoint = manifest.Endpoint, server_public_key = manifest.ServerPublicKey,
                assigned_ipv4 = ClientIp + "/32", dns = new[] { ServerIp }, allowed_ips = new[] { ServerIp + "/32" },
                mtu = 1360, persistent_keepalive = 1,
                amnezia = new
                {
                    jc = 2, jmin = 64, jmax = 128, s1 = 12, s2 = 12, s3 = 12, s4 = 12,
                    h1 = "100001-100010", h2 = "200001-200010", h3 = "300001-300010", h4 = "400001-400010",
                    header_protection_key = manifest.HeaderProtectionKey, content_padding_addition = "16-32",
                    rekey_after_time = "120-130", rekey_timeout = "5-6", reject_after_time = "180-190",
                    keepalive_timeout = "10-12", max_handshake_attempts = "18-20", random_trailers = "1", disable_cookies = "0",
                },
            },
        });
        var signature = key.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        var verifier = new VpnSignedProfileVerifier([new VpnProfileSigningKey("ci-fixture",
            VpnSignedProfileVerifier.SupportedAlgorithm, Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()))]);
        var envelope = new VpnProfileAuthorization("ci-fixture", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(payload), Convert.ToBase64String(signature));
        var tampered = payload.ToArray(); tampered[^2] ^= 1;
        var rejected = false;
        try { verifier.Authorize(new VpnProfileAuthorization(envelope.KeyId, envelope.Algorithm,
            Convert.ToBase64String(tampered), envelope.SignatureBase64), manifest.ClientPrivateKey); }
        catch (VpnTunnelException) { rejected = true; }
        Require(rejected, "fixture_tampered_profile_admitted");
        result["tampered_signature_rejected"] = true;
        var profile = verifier.Authorize(envelope, manifest.ClientPrivateKey);
        Require(profile.TunnelConfig.Contains("RandomTrailers = on", StringComparison.Ordinal) &&
            profile.TunnelConfig.Contains("DisableCookies = off", StringComparison.Ordinal), "fixture_awg31_flags_not_materialized");
        result["signed_profile_materialized"] = true;
        return profile;
    }

    private static Socket TunnelSocket(SocketType type, ProtocolType protocol, int adapterIndex)
    {
        var socket = new Socket(AddressFamily.InterNetwork, type, protocol);
        try
        {
            // Windows IP_UNICAST_IF takes the interface index in network order.
            socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31 /* IP_UNICAST_IF */, IPAddress.HostToNetworkOrder(adapterIndex));
            socket.Bind(new IPEndPoint(IPAddress.Parse(ClientIp), 0));
            return socket;
        }
        catch { socket.Dispose(); throw; }
    }

    private static async Task ProbeDnsAsync(int adapterIndex, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var socket = TunnelSocket(SocketType.Dgram, ProtocolType.Udp, adapterIndex);
        await socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(ServerIp), 53), timeout.Token);
        var query = new List<byte>([0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        var id = RandomNumberGenerator.GetBytes(2); query[0] = id[0]; query[1] = id[1];
        foreach (var label in Host.Split('.')) { query.Add((byte)label.Length); query.AddRange(Encoding.ASCII.GetBytes(label)); }
        query.AddRange([0, 0, 1, 0, 1]);
        await socket.SendAsync(query.ToArray(), SocketFlags.None, timeout.Token);
        var buffer = new byte[1232];
        var length = await socket.ReceiveAsync(buffer, SocketFlags.None, timeout.Token);
        Require(length >= 12 && buffer[0] == id[0] && buffer[1] == id[1] && (buffer[2] & 0x80) != 0 &&
            (buffer[3] & 0x0f) == 0 && BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(4)) == 1 &&
            BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(6)) == 1, "fixture_dns_response_invalid");
        var position = 12;
        SkipDnsName(buffer.AsSpan(0, length), ref position);
        Require(position + 4 <= length && buffer[position] == 0 && buffer[position + 1] == 1 &&
            buffer[position + 2] == 0 && buffer[position + 3] == 1, "fixture_dns_question_invalid");
        position += 4;
        SkipDnsName(buffer.AsSpan(0, length), ref position);
        Require(position + 14 <= length && BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(position)) == 1 &&
            BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(position + 2)) == 1 &&
            BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(position + 8)) == 4 &&
            buffer.AsSpan(position + 10, 4).SequenceEqual(IPAddress.Parse(ServerIp).GetAddressBytes()), "fixture_dns_answer_invalid");
    }

    private static void SkipDnsName(ReadOnlySpan<byte> packet, ref int position)
    {
        for (var labels = 0; labels < 128 && position < packet.Length; labels++)
        {
            var length = packet[position++];
            if (length == 0) { return; }
            if ((length & 0xc0) == 0xc0) { Require(position < packet.Length, "fixture_dns_name_invalid"); position++; return; }
            Require(length <= 63 && position + length <= packet.Length, "fixture_dns_name_invalid");
            position += length;
        }
        throw new InvalidOperationException("fixture_dns_name_invalid");
    }

    private static async Task ProbeHttpsAsync(int adapterIndex, string directory, CancellationToken cancellationToken)
    {
        using var root = X509Certificate2.CreateFromPem(
            await File.ReadAllTextAsync(Path.Combine(directory, "root.pem"), cancellationToken));
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false, AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(10),
            SslOptions = new SslClientAuthenticationOptions
            {
                CertificateChainPolicy = new X509ChainPolicy
                { TrustMode = X509ChainTrustMode.CustomRootTrust, RevocationMode = X509RevocationMode.NoCheck },
            },
            ConnectCallback = async (_, token) =>
            {
                var socket = TunnelSocket(SocketType.Stream, ProtocolType.Tcp, adapterIndex);
                try { await socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(ServerIp), 443), token); return new NetworkStream(socket, ownsSocket: true); }
                catch { socket.Dispose(); throw; }
            },
        };
        handler.SslOptions.CertificateChainPolicy!.CustomTrustStore.Add(root);
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        using var response = await client.GetAsync("https://" + Host + "/health?nonce=" + nonce, cancellationToken);
        Require(response.IsSuccessStatusCode && await response.Content.ReadAsStringAsync(cancellationToken) == "vex-vpn-fixture:" + nonce,
            "fixture_https_payload_invalid");
    }

    private static async Task<PeerStatus> ReadPeerStatusAsync(string directory, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(5);
        do
        {
            try
            {
                var status = JsonSerializer.Deserialize<PeerStatus>(await File.ReadAllTextAsync(Path.Combine(directory, "peer-status.json"), cancellationToken));
                if (status is { Schema: "vex.windows-vpn-peer-status.v1", DnsRequests: > 0, HttpsRequests: > 0 }) { return status; }
            }
            catch (IOException) { }
            catch (JsonException) { }
            await Task.Delay(100, cancellationToken);
        } while (DateTimeOffset.UtcNow < deadline);
        throw new InvalidOperationException("fixture_peer_status_timeout");
    }

    private static void Require(bool condition, string code) { if (!condition) { throw new FixtureException(code); } }

    private sealed class FixtureException(string code) : Exception("The isolated VPN fixture rejected this operation.")
    {
        public string Code { get; } = code;
    }

    private sealed record Manifest(
        [property: JsonPropertyName("schema")] string Schema,
        [property: JsonPropertyName("client_private_key")] string ClientPrivateKey,
        [property: JsonPropertyName("server_public_key")] string ServerPublicKey,
        [property: JsonPropertyName("header_protection_key")] string HeaderProtectionKey,
        [property: JsonPropertyName("endpoint")] string Endpoint,
        [property: JsonPropertyName("server_ip")] string ServerIp,
        [property: JsonPropertyName("client_ip")] string ClientIp);
    private sealed record PeerStatus(
        [property: JsonPropertyName("schema")] string Schema,
        [property: JsonPropertyName("handshake_unix")] long HandshakeUnix,
        [property: JsonPropertyName("rx_bytes")] long RxBytes,
        [property: JsonPropertyName("tx_bytes")] long TxBytes,
        [property: JsonPropertyName("dns_requests")] long DnsRequests,
        [property: JsonPropertyName("https_requests")] long HttpsRequests);
}

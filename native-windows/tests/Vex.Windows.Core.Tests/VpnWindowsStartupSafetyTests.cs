using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

internal static class VpnWindowsStartupSafetyTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
    private static readonly string Peer = Convert.ToBase64String(Enumerable.Repeat((byte)7, 32).ToArray());
    private static readonly string OtherPeer = Convert.ToBase64String(Enumerable.Repeat((byte)8, 32).ToArray());
    public static readonly (string Name, Action Run)[] All =
    [
        ("Windows full routes preserve exact IPv4/IPv6 coverage without vendor /0 WFP policy", FullCoverageIsExact),
        ("Windows route materialization preserves split prefixes and refuses malformed CIDR", SplitRoutesStayScoped),
        ("Signed dual-stack profiles materialize assigned IPv6 and both full-route halves", SignedDualStackMaterializes),
        ("Signed profiles reject invalid IPv6 assignments, small IPv6 MTU and unusable IPv6 DNS", InvalidDualStackFailsClosed),
        ("IPv4-only signed profiles retain IPv4 routes and never fabricate an IPv6 assignment", LegacyIpv4RemainsCompatible),
        ("Cold hostname startup uses the exact admitted numeric peer without changing signed source", OfflineStartupUsesScopedCache),
        ("Cold hostname startup refuses changed peer, port, expired lease and corrupted configuration", StartupBindingsFailClosed),
        ("Numeric IPv4 and IPv6 startup preserve signed port without needing DNS metadata", LiteralStartupNeedsNoDns),
        ("Owned vendor registration accepts only exact executable/config/service contract", VendorOwnershipIsExact),
        ("Owned vendor registration accepts only Automatic migration or Demand startup", VendorStartupPolicyIsDemand),
    ];

    private static void FullCoverageIsExact()
    {
        var routes = VpnWindowsRouteMaterializer.Materialize(["0.0.0.0/0", "::/0"], true);
        Require(routes.SequenceEqual(["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]), "Full route halves changed.");
        foreach (var value in new[] { "0.0.0.0", "127.255.255.255", "128.0.0.0", "255.255.255.255", "::", "7fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "8000::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" })
        {
            var address = IPAddress.Parse(value);
            Require(routes.Count(route => Covers(route, address)) == 1, "Full coverage has a hole or overlapping family: " + value);
        }
    }

    private static bool Covers(string route, IPAddress address)
    {
        var parts = route.Split('/');
        var network = IPAddress.Parse(parts[0]);
        return network.AddressFamily == address.AddressFamily &&
            (network.GetAddressBytes()[0] & 128) == (address.GetAddressBytes()[0] & 128);
    }

    private static void SplitRoutesStayScoped()
    {
        Require(VpnWindowsRouteMaterializer.Materialize(["10.0.0.0/8", "192.0.2.5/32", "2001:db8::/48"], true)
            .SequenceEqual(["10.0.0.0/8", "192.0.2.5/32", "2001:db8::/48"]), "Split routes expanded.");
        foreach (var invalid in new[] { "nonsense", "0.0.0.0/-1", "192.0.2.1/33", "::/129" })
        {
            Rejected(() => VpnWindowsRouteMaterializer.Materialize([invalid], true), "profile_allowed_ips_invalid");
        }
    }

    private static void SignedDualStackMaterializes()
    {
        var profile = SignedProfile("2001:db8:1::2/128", ["0.0.0.0/0", "::/0"], ["10.0.0.1", "2001:db8:1::1"], 1360);
        Require(profile.TunnelConfig.Contains("Address = 10.0.0.2/32, 2001:db8:1::2/128", StringComparison.Ordinal) &&
            profile.TunnelConfig.Contains("AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1", StringComparison.Ordinal),
            "Signed dual-stack assignment or full routes were lost.");
    }

    private static void InvalidDualStackFailsClosed()
    {
        foreach (var assignment in new[] { "", "192.0.2.1/32", "2001:db8::/129", "2001:db8::2/128\nPostUp = cmd" })
        {
            Rejected(() => SignedProfile(assignment, ["0.0.0.0/0", "::/0"], ["10.0.0.1"], 1360), "profile_assigned_ipv6_invalid");
        }
        Rejected(() => SignedProfile("2001:db8::2/128", ["0.0.0.0/0", "::/0"], ["10.0.0.1"], 1200), "profile_transport_invalid");
        Rejected(() => SignedProfile(null, ["0.0.0.0/0", "::/0"], ["2001:db8::1"], 1360), "profile_dns_invalid");
    }

    private static void LegacyIpv4RemainsCompatible()
    {
        var profile = SignedProfile(null, ["0.0.0.0/0", "::/0"], ["10.0.0.1"], 1360);
        Require(profile.TunnelConfig.Contains("Address = 10.0.0.2/32\n", StringComparison.Ordinal) &&
            profile.TunnelConfig.Contains("AllowedIPs = 0.0.0.0/1, 128.0.0.0/1\n", StringComparison.Ordinal),
            "Legacy IPv4 assignment or route behavior changed.");
    }

    private static VpnAuthorizedProfile SignedProfile(string? ipv6, string[] routes, string[] dns, int mtu)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schema = "vex.native-vpn-profile.v1", profile_version = 1,
            user_id = "test-user", device_id = "test-device", requested_location_id = "test-location", assigned_location_id = "test-location",
            routing_mode = "full", bypass_region = "", routing_policy_version = "test-policy",
            issued_at = Now, expires_at = Now.AddMinutes(10),
            tunnel = new { protocol = "amneziawg", endpoint = "vpn.example.test:443", server_public_key = Peer,
                assigned_ipv4 = "10.0.0.2/32", assigned_ipv6 = ipv6, dns, allowed_ips = routes, mtu, persistent_keepalive = 25 },
        });
        var signature = key.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        var verifier = new VpnSignedProfileVerifier([new("test", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()))], () => Now);
        return verifier.Authorize(new("test", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(payload), Convert.ToBase64String(signature)), Peer);
    }

    private static string Configuration(string endpoint = "vpn.example.test:443", string? peer = null) =>
        "[Interface]\nPrivateKey = " + Peer + "\nAddress = 10.0.0.2/32\nDNS = 10.0.0.1\nMTU = 1360\n\n[Peer]\nPublicKey = " +
        (peer ?? Peer) + "\nEndpoint = " + endpoint + "\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n";
    private static string Hash(string config) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(config)));
    private static VpnEndpointAddressSnapshot Snapshot() => new("vpn.example.test:443", Peer, Now.AddMinutes(10), ["192.0.2.7"]);

    private static void OfflineStartupUsesScopedCache()
    {
        var config = Configuration();
        var vendor = VpnVendorStartupConfiguration.Materialize(config, Hash(config), Snapshot(), Now.AddMinutes(10), Now);
        Require(vendor.Contains("Endpoint = 192.0.2.7:443", StringComparison.Ordinal) &&
            vendor.Contains("AllowedIPs = 0.0.0.0/1, 128.0.0.0/1", StringComparison.Ordinal) &&
            config.Contains("Endpoint = vpn.example.test:443", StringComparison.Ordinal), "Offline startup mutated signed hostname/source.");
    }

    private static void StartupBindingsFailClosed()
    {
        var config = Configuration();
        foreach (var snapshot in new VpnEndpointAddressSnapshot?[] { null, Snapshot() with { ServerPublicKey = OtherPeer },
            Snapshot() with { Endpoint = "vpn.example.test:8443" }, Snapshot() with { Endpoint = "other.example.test:443" },
            Snapshot() with { ValidUntil = Now }, Snapshot() with { ValidUntil = Now.AddMinutes(9) },
            Snapshot() with { ValidUntil = Now.AddMinutes(11) },
            Snapshot() with { Addresses = ["not-numeric"] }, Snapshot() with { Addresses = [] } })
        {
            Rejected(() => VpnVendorStartupConfiguration.Materialize(config, Hash(config), snapshot, Now.AddMinutes(10), Now), "endpoint_resolution_failed");
        }
        Rejected(() => VpnVendorStartupConfiguration.Materialize(config, Hash(config), Snapshot(), Now, Now), "profile_expired");
        Rejected(() => VpnVendorStartupConfiguration.Materialize(config, Hash(Configuration("other.example.test:443")), Snapshot(), Now.AddMinutes(10), Now), "tunnel_runtime_integrity_failure");
    }

    private static void LiteralStartupNeedsNoDns()
    {
        foreach (var endpoint in new[] { "192.0.2.7:8443", "[2001:db8::7]:8443" })
        {
            var config = Configuration(endpoint);
            var vendor = VpnVendorStartupConfiguration.Materialize(config, Hash(config), null, Now.AddMinutes(10), Now);
            Require(vendor.Contains("Endpoint = " + endpoint, StringComparison.Ordinal), "Numeric signed endpoint/port changed.");
        }
    }

    private static bool Identity(string[]? command = null, uint type = 16, uint start = 3, string account = "LocalSystem",
        string[]? dependencies = null, uint sid = 1) => VpnVendorServiceIdentity.Matches(command ?? ["C:\\VEX\\amneziawg.exe", "/tunnelservice", "C:\\VEX\\Private\\vex.conf"],
            "C:\\VEX\\amneziawg.exe", "C:\\VEX\\Private\\vex.conf", type, start, account, dependencies ?? ["Nsi", "TcpIp"], sid);

    private static void VendorOwnershipIsExact()
    {
        Require(Identity(), "Exact vendor registration was rejected.");
        foreach (var command in new[] { new[] { "C:\\other\\amneziawg.exe", "/tunnelservice", "C:\\VEX\\Private\\vex.conf" },
            new[] { "C:\\VEX\\amneziawg.exe", "/managerservice", "C:\\VEX\\Private\\vex.conf" },
            new[] { "C:\\VEX\\amneziawg.exe", "/tunnelservice", "C:\\other\\vex.conf" },
            new[] { "C:\\VEX\\amneziawg.exe", "/tunnelservice", "C:\\VEX\\Private\\vex.conf", "extra" } })
        { Require(!Identity(command), "Foreign vendor command was adopted."); }
        Require(!Identity(type: 32) && !Identity(account: "Administrator") && !Identity(dependencies: ["Nsi"]) &&
            !Identity(dependencies: ["Nsi", "TcpIp", "foreign"]) && !Identity(sid: 0), "Foreign service contract was adopted.");
    }

    private static void VendorStartupPolicyIsDemand()
    {
        Require(Identity(start: VpnVendorServiceIdentity.DemandStart) && Identity(start: VpnVendorServiceIdentity.AutomaticStart),
            "Demand startup or qualified legacy migration was rejected.");
        foreach (var value in new uint[] { 0, 1, 4, uint.MaxValue })
        { Require(!Identity(start: value), "Unexpected startup policy was accepted."); }
    }

    private static void Rejected(Action action, string code)
    {
        try { action(); }
        catch (VpnTunnelException error) when (error.Code == code) { return; }
        throw new InvalidOperationException("Expected startup safety rejection: " + code);
    }
    private static void Require(bool condition, string message) { if (!condition) { throw new InvalidOperationException(message); } }
}

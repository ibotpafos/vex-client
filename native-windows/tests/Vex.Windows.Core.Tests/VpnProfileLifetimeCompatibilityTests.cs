using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

internal static class VpnProfileLifetimeCompatibilityTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-11T00:00:00Z");
    private static readonly string Peer = Convert.ToBase64String(Enumerable.Repeat((byte)7, 32).ToArray());
    private const string Endpoint = "vpn.example.test:443";
    private static readonly string[] Hosts = ["api.example.test"];

    public static readonly (string Name, Action Run)[] All =
    [
        ("Signed 24-hour hostname profiles survive one-minute issuer clock skew and restart", () => SignedProfileSurvivesSkew(TimeSpan.FromMinutes(1))),
        ("Signed 24-hour hostname profiles preserve the exact two-minute skew boundary", () => SignedProfileSurvivesSkew(TimeSpan.FromMinutes(2))),
        ("Signed profile authority still rejects excess issuer skew and lifetime", ExcessSignedAuthorityFailsClosed),
        ("Endpoint and control-plane admission still reject remaining lifetime beyond accepted skew", ExcessRemainingLifetimeFailsClosed),
        ("Skew-compatible hostname startup cannot extend expiry or change peer and port", StartupScopeAndExpiryRemainExact),
    ];

    private static VpnAuthorizedProfile Authorize(DateTimeOffset issuedAt, DateTimeOffset expiresAt)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            schema = "vex.native-vpn-profile.v1", profile_version = 1,
            user_id = "test-user", device_id = "test-device", requested_location_id = "test-location", assigned_location_id = "test-location",
            routing_mode = "full", bypass_region = "", routing_policy_version = "test-policy",
            issued_at = issuedAt, expires_at = expiresAt,
            tunnel = new { protocol = "amneziawg", endpoint = Endpoint, server_public_key = Peer,
                assigned_ipv4 = "10.0.0.2/32", dns = new[] { "10.0.0.1" }, allowed_ips = new[] { "0.0.0.0/0" },
                mtu = 1360, persistent_keepalive = 25 },
        });
        var signature = key.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        return new VpnSignedProfileVerifier([new("test", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()))], () => Now).Authorize(
                new("test", VpnSignedProfileVerifier.SupportedAlgorithm, Convert.ToBase64String(payload), Convert.ToBase64String(signature)), Peer);
    }

    private static void SignedProfileSurvivesSkew(TimeSpan skew)
    {
        var issuedAt = Now + skew;
        var profile = Authorize(issuedAt, issuedAt.AddHours(24));
        var endpoint = new VpnEndpointAddressCache();
        Require(endpoint.RememberResolved(Endpoint, Peer, [IPAddress.Parse("192.0.2.7")], profile.ExpiresAt, Now),
            "A verified profile lost its numeric endpoint at the accepted clock skew.");
        var controls = new VpnControlPlaneAddressCache();
        Require(controls.Remember(Endpoint, Peer, Hosts,
            new Dictionary<string, IPAddress[]> { [Hosts[0]] = [IPAddress.Parse("198.51.100.7")] }, profile.ExpiresAt, Now),
            "A verified profile lost its control-plane answers at the accepted clock skew.");
        var restartedEndpoint = new VpnEndpointAddressCache();
        var restartedControls = new VpnControlPlaneAddressCache();
        Require(restartedEndpoint.Restore(JsonSerializer.Deserialize<VpnEndpointAddressSnapshot>(JsonSerializer.Serialize(endpoint.Snapshot)), Now) &&
            restartedControls.Restore(JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(JsonSerializer.Serialize(controls.Snapshot)), Hosts, Now),
            "Restart discarded a still-authorized skew-compatible routing snapshot.");
        Require(restartedEndpoint.Snapshot!.ValidUntil == profile.ExpiresAt && restartedControls.Snapshot!.ValidUntil == profile.ExpiresAt,
            "Clock skew changed the exact signed expiry.");
        var vendor = VpnVendorStartupConfiguration.Materialize(profile.TunnelConfig, Hash(profile.TunnelConfig),
            restartedEndpoint.Snapshot, profile.ExpiresAt, Now);
        Require(vendor.Contains("Endpoint = 192.0.2.7:443", StringComparison.Ordinal) &&
            vendor.Contains("AllowedIPs = 0.0.0.0/1, 128.0.0.0/1", StringComparison.Ordinal),
            "The admitted signed hostname did not produce the exact numeric startup target and routes.");
        Require(restartedEndpoint.Get(Endpoint, Peer, profile.ExpiresAt).Count == 0 &&
            restartedControls.Get(Endpoint, Peer, Hosts, profile.ExpiresAt, profile.ExpiresAt).Count == 0,
            "Clock skew extended routing answers beyond their original signed expiry.");
        Rejected(() => VpnVendorStartupConfiguration.Materialize(profile.TunnelConfig, Hash(profile.TunnelConfig),
            restartedEndpoint.Snapshot, profile.ExpiresAt, profile.ExpiresAt), "profile_expired");
    }

    private static void ExcessSignedAuthorityFailsClosed()
    {
        Rejected(() => Authorize(Now.AddMinutes(2).AddTicks(1), Now.AddMinutes(2).AddHours(24).AddTicks(1)), "profile_expired");
        Rejected(() => Authorize(Now.AddMinutes(1), Now.AddMinutes(1).AddHours(24).AddTicks(1)), "profile_expired");
        Rejected(() => Authorize(Now.AddHours(-24), Now), "profile_expired");
    }

    private static void ExcessRemainingLifetimeFailsClosed()
    {
        var expiry = Now.AddHours(24).AddMinutes(2).AddTicks(1);
        var endpoint = new VpnEndpointAddressCache();
        Require(!endpoint.RememberResolved(Endpoint, Peer, [IPAddress.Parse("192.0.2.7")], expiry, Now) &&
            !endpoint.Restore(new(Endpoint, Peer, expiry, ["192.0.2.7"]), Now),
            "An excessive remaining lease admitted an endpoint answer.");
        var controls = new VpnControlPlaneAddressCache();
        Require(!controls.Remember(Endpoint, Peer, Hosts,
            new Dictionary<string, IPAddress[]> { [Hosts[0]] = [IPAddress.Parse("198.51.100.7")] }, expiry, Now) &&
            !controls.Restore(new(1, Hosts, Endpoint, Peer, expiry, [new(Hosts[0], ["198.51.100.7"])]), Hosts, Now),
            "An excessive remaining lease admitted a control-plane answer.");
        var profile = Authorize(Now, Now.AddHours(24));
        Rejected(() => VpnVendorStartupConfiguration.Materialize(profile.TunnelConfig, Hash(profile.TunnelConfig),
            new(Endpoint, Peer, expiry, ["192.0.2.7"]), expiry, Now), "endpoint_resolution_failed");
    }

    private static void StartupScopeAndExpiryRemainExact()
    {
        var profile = Authorize(Now.AddMinutes(1), Now.AddHours(24).AddMinutes(1));
        var snapshot = new VpnEndpointAddressSnapshot(Endpoint, Peer, profile.ExpiresAt, ["192.0.2.7"]);
        foreach (var changed in new[]
        {
            snapshot with { ValidUntil = profile.ExpiresAt.AddTicks(1) },
            snapshot with { Endpoint = "vpn.example.test:8443" },
            snapshot with { Endpoint = "other.example.test:443" },
            snapshot with { ServerPublicKey = Convert.ToBase64String(new byte[32]) },
        })
        {
            Rejected(() => VpnVendorStartupConfiguration.Materialize(profile.TunnelConfig, Hash(profile.TunnelConfig),
                changed, profile.ExpiresAt, Now), "endpoint_resolution_failed");
        }
    }

    private static string Hash(string configuration) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(configuration)));
    private static void Rejected(Action action, string code)
    {
        try { action(); }
        catch (VpnTunnelException error) when (error.Code == code) { return; }
        throw new InvalidOperationException("Expected lifetime rejection: " + code);
    }
    private static void Require(bool condition, string message) { if (!condition) { throw new InvalidOperationException(message); } }
}

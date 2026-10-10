using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vex.Windows.Core.Vpn;

internal static class RuntimeParityTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    private static readonly string Key = Convert.ToBase64String(new byte[32]);

    public static readonly (string Name, Action Run)[] All =
    [
        ("Signed AWG 3.1 preserves all macOS features", FullAwg31Profile),
        ("Signed AWG flags normalize without weakening invalid input", FlagsFailClosed),
        ("AWG admission rejects malformed ranges and overlapping headers", RangesFailClosed),
        ("AWG header protection validates key and required nonce padding", HeaderProtectionFailsClosed),
        ("AWG admission rejects duplicate managed directives", DuplicateDirectiveFailsClosed),
        ("IPv4 managed profiles omit unusable IPv6 routes", Ipv4ProfileSanitizesIpv6),
        ("Signed network policy rejects explicit null fields safely", NullNetworkFieldsFailClosed),
        ("Signed regional routing accepts the complete Windows route budget", RegionalRouteBudget),
        ("Peer statistics select only the configured server", PeerSelectionIsExact),
        ("Peer statistics reject incomplete or failed UAPI replies", PeerRepliesFailClosed),
        ("Outbound bytes cannot verify a VPN handshake", HandshakeIsRequired),
        ("Handshake health rejects stale and future peer timestamps", HandshakeFreshness),
    ];

    private static JsonObject Profile()
    {
        return new JsonObject
        {
            ["schema"] = "vex.native-vpn-profile.v1",
            ["profile_version"] = 1,
            ["user_id"] = "user-1",
            ["device_id"] = "device-1",
            ["requested_location_id"] = "fi-1",
            ["assigned_location_id"] = "fi-1",
            ["routing_mode"] = "full",
            ["bypass_region"] = "",
            ["routing_policy_version"] = "routes-1",
            ["issued_at"] = Now.AddMinutes(-1).ToString("O"),
            ["expires_at"] = Now.AddHours(1).ToString("O"),
            ["tunnel"] = new JsonObject
            {
                ["protocol"] = "amneziawg",
                ["endpoint"] = "198.51.100.10:443",
                ["server_public_key"] = Key,
                ["assigned_ipv4"] = "10.64.1.25/32",
                ["dns"] = new JsonArray("1.1.1.1"),
                ["allowed_ips"] = new JsonArray("0.0.0.0/0", "::/0"),
                ["mtu"] = 1360,
                ["persistent_keepalive"] = 25,
            },
        };
    }

    private static JsonObject Features() => new()
    {
        ["jc"] = 4, ["jmin"] = 10, ["jmax"] = 20,
        ["s1"] = 12, ["s2"] = 12, ["s3"] = 12, ["s4"] = 12,
        ["h1"] = "100-110", ["h2"] = "200-210", ["h3"] = "300-310", ["h4"] = "400-410",
        ["i1"] = "<b 0x01020304>", ["i2"] = "<r 8>", ["i3"] = "<t>", ["i4"] = "<rc 4>", ["i5"] = "<d>",
        ["header_protection_key"] = Convert.ToBase64String(Enumerable.Repeat((byte)1, 32).ToArray()),
        ["content_padding_addition"] = "1-2",
        ["rekey_after_time"] = "100-120", ["rekey_timeout"] = "5-10",
        ["reject_after_time"] = "160-180", ["keepalive_timeout"] = "20-25",
        ["max_handshake_attempts"] = "10-15",
        ["random_trailers"] = "true", ["disable_cookies"] = "0",
    };

    private static VpnAuthorizedProfile Authorize(JsonObject profile)
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var payload = JsonSerializer.SerializeToUtf8Bytes(profile);
        var authorization = new VpnProfileAuthorization("key-1", VpnSignedProfileVerifier.SupportedAlgorithm,
            Convert.ToBase64String(payload), Convert.ToBase64String(signingKey.SignData(payload,
                HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
        var verifier = new VpnSignedProfileVerifier([new VpnProfileSigningKey("key-1",
            VpnSignedProfileVerifier.SupportedAlgorithm, Convert.ToBase64String(signingKey.ExportSubjectPublicKeyInfo()))], () => Now);
        return verifier.Authorize(authorization, Key);
    }

    private static void FullAwg31Profile()
    {
        var profile = Profile();
        var features = Features();
        profile["tunnel"]!["amnezia"] = features;
        var configuration = Authorize(profile).TunnelConfig;
        var names = new[] { "HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout",
            "RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies" };
        foreach (var name in names)
        {
            if (configuration.Split('\n').Count(line => line.StartsWith(name + " = ", StringComparison.Ordinal)) != 1)
            {
                throw new Exception("AWG feature was omitted or duplicated: " + name);
            }
        }
        Require(configuration.Contains("RekeyTimeout = 5-10\n", StringComparison.Ordinal));
        Require(configuration.Contains("RandomTrailers = on\n", StringComparison.Ordinal));
        Require(configuration.Contains("DisableCookies = off\n", StringComparison.Ordinal));
        VpnTunnelConfigurationValidator.Validate(configuration);
    }

    private static void FlagsFailClosed()
    {
        var profile = Profile();
        var features = Features();
        features["random_trailers"] = "maybe";
        profile["tunnel"]!["amnezia"] = features;
        Rejects(() => Authorize(profile));
    }

    private static void RangesFailClosed()
    {
        foreach (var value in new[] { "20-10", "-1", "1-2-3", "4294967296", "1\nPostUp=command" })
        {
            var profile = Profile();
            var features = Features();
            features["rekey_timeout"] = value;
            profile["tunnel"]!["amnezia"] = features;
            Rejects(() => Authorize(profile));
        }
        var overlapping = Profile();
        var overlapFeatures = Features();
        overlapFeatures["h2"] = "105-200";
        overlapping["tunnel"]!["amnezia"] = overlapFeatures;
        Rejects(() => Authorize(overlapping));
    }

    private static void HeaderProtectionFailsClosed()
    {
        foreach (var field in new[] { "header_protection_key", "s4" })
        {
            var profile = Profile();
            var features = Features();
            if (field == "s4") { features[field] = 11; }
            else { features[field] = "invalid"; }
            profile["tunnel"]!["amnezia"] = features;
            Rejects(() => Authorize(profile));
        }
    }

    private static void DuplicateDirectiveFailsClosed()
    {
        var config = Authorize(Profile()).TunnelConfig;
        Rejects(() => VpnTunnelConfigurationValidator.Validate(config.Replace("MTU = 1360", "MTU = 1360\nMTU = 1500", StringComparison.Ordinal)));
    }

    private static void Ipv4ProfileSanitizesIpv6()
    {
        var config = Authorize(Profile()).TunnelConfig;
        Require(config.Contains("AllowedIPs = 0.0.0.0/0\n", StringComparison.Ordinal));
        Require(!config.Contains("::/0", StringComparison.Ordinal));
        var profile = Profile();
        profile["tunnel"]!["allowed_ips"] = new JsonArray("::/0");
        Rejects(() => Authorize(profile));
    }

    private static void PeerSelectionIsExact()
    {
        var expected = Convert.ToHexString(new byte[32]);
        var peer = VpnPeerStatistics.Parse([
            "private_key=redacted",
            "public_key=" + new string('1', 64), "last_handshake_time_sec=2000000000", "rx_bytes=999", "tx_bytes=999",
            "public_key=" + expected, "last_handshake_time_sec=1999999999", "rx_bytes=123", "tx_bytes=456", "errno=0",
        ], Key);
        Require(peer.LatestHandshakeAt == Now.AddSeconds(-1));
        Require(peer.RxBytes == 123 && peer.TxBytes == 456);
    }

    private static void NullNetworkFieldsFailClosed()
    {
        var profile = Profile();
        profile["tunnel"] = null;
        Rejects(() => Authorize(profile));
        profile = Profile();
        profile["tunnel"]!["assigned_ipv4"] = null;
        Rejects(() => Authorize(profile));
        profile = Profile();
        profile["tunnel"]!["allowed_ips"] = new JsonArray((JsonNode?)null);
        Rejects(() => Authorize(profile));
    }

    private static void RegionalRouteBudget()
    {
        var profile = Profile();
        profile["tunnel"]!["allowed_ips"] = new JsonArray(Enumerable.Range(0, 2048)
            .Select(index => JsonValue.Create($"10.{index / 256}.{index % 256}.0/24")).ToArray<JsonNode?>());
        var configuration = Authorize(profile).TunnelConfig;
        Require(configuration.Contains("10.7.255.0/24", StringComparison.Ordinal));
        VpnTunnelConfigurationValidator.Validate(configuration);
    }

    private static void PeerRepliesFailClosed()
    {
        var peerKey = "public_key=" + Convert.ToHexString(new byte[32]);
        Rejects(() => VpnPeerStatistics.Parse([peerKey, "last_handshake_time_sec=1"], Key));
        Rejects(() => VpnPeerStatistics.Parse([peerKey, "errno=5"], Key));
        Rejects(() => VpnPeerStatistics.Parse([peerKey, "rx_bytes=-1", "errno=0"], Key));
        Rejects(() => VpnPeerStatistics.Parse([peerKey, "last_handshake_time_sec=999999999999", "errno=0"], Key));
        Rejects(() => VpnPeerStatistics.Parse(["errno=0"], Key));
    }

    private static void HandshakeIsRequired()
    {
        var peer = new VpnPeerStatistics(null, 0, 10_000);
        Require(!peer.HasFreshHandshake(Now, TimeSpan.FromSeconds(180)));
        var diagnostics = new VpnTunnelDiagnostics("vex", 5, "198.51.100.10:443", 0, 10_000, null,
            true, true, true, true, VpnLeakProtectionState.Armed, ["1.1.1.1"], []);
        Require(!diagnostics.IsUsable);
        Require((diagnostics with { LatestHandshakeAt = Now }).IsUsable);
        Require(!(diagnostics with { LatestHandshakeAt = Now, Findings = ["handshake_stale"] }).IsUsable);
    }

    private static void HandshakeFreshness()
    {
        Require(new VpnPeerStatistics(Now.AddSeconds(-179), 1, 1).HasFreshHandshake(Now, TimeSpan.FromSeconds(180)));
        Require(!new VpnPeerStatistics(Now.AddSeconds(-181), 1, 1).HasFreshHandshake(Now, TimeSpan.FromSeconds(180)));
        Require(!new VpnPeerStatistics(Now.AddSeconds(3), 1, 1).HasFreshHandshake(Now, TimeSpan.FromSeconds(180)));
    }

    private static void Require(bool value) { if (!value) { throw new Exception("Runtime parity assertion failed."); } }
    private static void Rejects(Action action)
    {
        try { action(); }
        catch (VpnTunnelException) { return; }
        throw new Exception("Invalid runtime input was accepted.");
    }
}

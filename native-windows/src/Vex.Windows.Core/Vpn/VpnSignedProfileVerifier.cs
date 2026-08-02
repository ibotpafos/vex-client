using System.Net;
using System.Net.Sockets;
using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vex.Windows.Core.Vpn;

public sealed record VpnProfileAuthorization
{
    public VpnProfileAuthorization(
        string keyId,
        string algorithm,
        string payloadBase64,
        string signatureBase64)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        ArgumentException.ThrowIfNullOrWhiteSpace(algorithm);
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadBase64);
        ArgumentException.ThrowIfNullOrWhiteSpace(signatureBase64);
        if (keyId.Length > 128 ||
            algorithm.Length > 64 ||
            payloadBase64.Length > 96 * 1024 ||
            signatureBase64.Length > 1024)
        {
            throw new ArgumentException(
                "The signed VPN profile authorization is too large.");
        }

        KeyId = keyId;
        Algorithm = algorithm;
        PayloadBase64 = payloadBase64;
        SignatureBase64 = signatureBase64;
    }

    public string KeyId { get; }

    public string Algorithm { get; }

    public string PayloadBase64 { get; }

    public string SignatureBase64 { get; }

    public override string ToString() =>
        $"{nameof(VpnProfileAuthorization)} {{ KeyId = {KeyId}, " +
        $"Algorithm = {Algorithm}, Payload = <redacted>, Signature = <redacted> }}";
}

public sealed record VpnProfileSigningKey
{
    public VpnProfileSigningKey(
        string keyId,
        string algorithm,
        string subjectPublicKeyInfoBase64)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        ArgumentException.ThrowIfNullOrWhiteSpace(algorithm);
        ArgumentException.ThrowIfNullOrWhiteSpace(subjectPublicKeyInfoBase64);
        KeyId = keyId;
        Algorithm = algorithm;
        SubjectPublicKeyInfoBase64 = subjectPublicKeyInfoBase64;
    }

    public string KeyId { get; }

    public string Algorithm { get; }

    public string SubjectPublicKeyInfoBase64 { get; }
}

public sealed record VpnAuthorizedProfile(
    string LocationId,
    string TunnelConfig,
    DateTimeOffset ExpiresAt);

public sealed class VpnSignedProfileVerifier
{
    public const string SupportedAlgorithm = "ECDSA_P256_SHA256_DER";

    private static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(2);
    // The control plane currently issues managed native profiles for 24 hours.
    // Reject any longer-lived authorization even when its signature is valid.
    private static readonly TimeSpan MaximumLifetime = TimeSpan.FromHours(24);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly IReadOnlyDictionary<string, VpnProfileSigningKey> _keys;
    private readonly Func<DateTimeOffset> _utcNow;

    public VpnSignedProfileVerifier(
        IEnumerable<VpnProfileSigningKey> keys,
        Func<DateTimeOffset>? utcNow = null)
    {
        ArgumentNullException.ThrowIfNull(keys);
        var keyMap = new Dictionary<string, VpnProfileSigningKey>(
            StringComparer.Ordinal);
        foreach (var key in keys)
        {
            ValidateSigningKey(key);
            if (!keyMap.TryAdd(key.KeyId, key))
            {
                throw new ArgumentException(
                    "VPN profile signing key IDs must be unique.",
                    nameof(keys));
            }
        }

        if (keyMap.Count == 0)
        {
            throw new ArgumentException(
                "At least one VPN profile signing key is required.",
                nameof(keys));
        }

        _keys = keyMap;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
    }

    private static void ValidateSigningKey(VpnProfileSigningKey key)
    {
        if (key.Algorithm != SupportedAlgorithm ||
            key.KeyId.Length > 128 ||
            key.SubjectPublicKeyInfoBase64.Length > 4096)
        {
            throw new ArgumentException(
                "The VPN profile signing key is invalid.",
                nameof(key));
        }

        try
        {
            using var verifier = ECDsa.Create();
            var publicKey = Convert.FromBase64String(
                key.SubjectPublicKeyInfoBase64);
            verifier.ImportSubjectPublicKeyInfo(publicKey, out var bytesRead);
            if (bytesRead != publicKey.Length || verifier.KeySize != 256)
            {
                throw new CryptographicException();
            }
        }
        catch (Exception error) when (
            error is CryptographicException or FormatException)
        {
            throw new ArgumentException(
                "The VPN profile signing key is invalid.",
                nameof(key),
                error);
        }
    }

    public VpnAuthorizedProfile Authorize(
        VpnProfileAuthorization authorization,
        string localPrivateKey)
    {
        ArgumentNullException.ThrowIfNull(authorization);
        ValidateWireGuardKey(localPrivateKey, "local_private_key_invalid");

        var payload = Decode(
            authorization.PayloadBase64,
            maximumBytes: 64 * 1024);
        var signature = Decode(
            authorization.SignatureBase64,
            maximumBytes: 512);
        VerifySignature(authorization, payload, signature);
        var policy = DeserializePolicy(payload);
        ValidatePolicy(policy);

        return new VpnAuthorizedProfile(
            policy.AssignedLocationId,
            BuildTunnelConfig(policy, localPrivateKey),
            policy.ExpiresAt);
    }

    private void VerifySignature(
        VpnProfileAuthorization authorization,
        byte[] payload,
        byte[] signature)
    {
        if (authorization.Algorithm != SupportedAlgorithm)
        {
            Reject("profile_signing_key_unknown");
        }

        if (!_keys.TryGetValue(authorization.KeyId, out var key))
        {
            Reject("profile_signing_key_unknown");
        }

        if (key.Algorithm != SupportedAlgorithm)
        {
            Reject("profile_signing_key_unknown");
        }

        try
        {
            using var verifier = ECDsa.Create();
            var publicKey = Convert.FromBase64String(
                key.SubjectPublicKeyInfoBase64);
            verifier.ImportSubjectPublicKeyInfo(
                publicKey,
                out var bytesRead);
            if (bytesRead != publicKey.Length ||
                verifier.KeySize != 256 ||
                !verifier.VerifyData(
                    payload,
                    signature,
                    HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence))
            {
                Reject("profile_signature_invalid");
            }
        }
        catch (Exception error) when (
            error is CryptographicException or FormatException)
        {
            Reject("profile_signature_invalid");
        }
    }

    private static SignedVpnProfilePolicy DeserializePolicy(byte[] payload)
    {
        try
        {
            return JsonSerializer.Deserialize<SignedVpnProfilePolicy>(
                payload,
                JsonOptions) ?? throw new JsonException();
        }
        catch (JsonException error)
        {
            Reject(PayloadErrorCode(error));
            throw;
        }
    }

    private static string PayloadErrorCode(JsonException error)
    {
        if (string.IsNullOrWhiteSpace(error.Path))
        {
            return "profile_payload_invalid";
        }

        var normalizedPath = new StringBuilder();
        foreach (var character in error.Path)
        {
            if (char.IsAsciiLetterOrDigit(character))
            {
                normalizedPath.Append(char.ToLowerInvariant(character));
            }
            else if (normalizedPath.Length > 0 &&
                     normalizedPath[^1] != '_')
            {
                normalizedPath.Append('_');
            }
        }

        var path = normalizedPath.ToString().Trim('_');
        var code = $"profile_payload_{path}_invalid";
        return path.Length > 0 && code.Length <= 64
            ? code
            : "profile_payload_invalid";
    }

    private void ValidatePolicy(SignedVpnProfilePolicy policy)
    {
        if (policy.Schema != "vex.native-vpn-profile.v1" ||
            policy.ProfileVersion < 1)
        {
            Reject("profile_metadata_invalid");
        }

        if (!SafeIdentifier(policy.UserId, 128) ||
            !SafeIdentifier(policy.DeviceId, 128))
        {
            Reject("profile_identity_invalid");
        }

        if (!SafeIdentifier(policy.AssignedLocationId, 128) ||
            !SafeIdentifier(policy.RoutingMode, 32))
        {
            Reject("profile_routing_invalid");
        }

        if (policy.Tunnel.Protocol != "amneziawg")
        {
            Reject("profile_protocol_unsupported");
        }

        var now = _utcNow();
        if (policy.IssuedAt > now + ClockSkew ||
            policy.ExpiresAt <= now ||
            policy.ExpiresAt <= policy.IssuedAt ||
            policy.ExpiresAt - policy.IssuedAt > MaximumLifetime)
        {
            Reject("profile_expired");
        }

        ValidateNetworkPolicy(policy);
    }

    private static void ValidateNetworkPolicy(SignedVpnProfilePolicy policy)
    {
        var tunnel = policy.Tunnel;
        ValidateEndpoint(tunnel.Endpoint);
        if (tunnel.Mtu is < 576 or > 9000 ||
            tunnel.PersistentKeepalive is < 0 or > 65535)
        {
            Reject("profile_transport_invalid");
        }

        ValidateWireGuardKey(
            tunnel.ServerPublicKey,
            "profile_server_public_key_invalid");
        if (!string.IsNullOrEmpty(tunnel.PresharedKey))
        {
            ValidateWireGuardKey(
                tunnel.PresharedKey,
                "profile_preshared_key_invalid");
        }

        ValidateCidr(
            tunnel.AssignedIpv4,
            AddressFamily.InterNetwork,
            "profile_assigned_ipv4_invalid");
        ValidateList(tunnel.Dns, 8, value =>
        {
            if (!IPAddress.TryParse(value, out _))
            {
                Reject("profile_dns_invalid");
            }
        }, "profile_dns_invalid");
        ValidateList(tunnel.AllowedIps, 2048, value =>
            ValidateCidr(
                value,
                expectedFamily: null,
                "profile_allowed_ips_invalid"),
            "profile_allowed_ips_invalid");
    }

    private static string BuildTunnelConfig(
        SignedVpnProfilePolicy policy,
        string localPrivateKey)
    {
        var tunnel = policy.Tunnel;
        var lines = new List<string>
        {
            "[Interface]",
            $"PrivateKey = {localPrivateKey}",
            $"Address = {tunnel.AssignedIpv4}",
            $"DNS = {string.Join(", ", tunnel.Dns)}",
            $"MTU = {tunnel.Mtu}",
        };
        tunnel.Amnezia?.AppendTo(lines);
        lines.Add(string.Empty);
        lines.Add("[Peer]");
        lines.Add($"PublicKey = {tunnel.ServerPublicKey}");
        if (!string.IsNullOrEmpty(tunnel.PresharedKey))
        {
            lines.Add($"PresharedKey = {tunnel.PresharedKey}");
        }

        lines.Add($"Endpoint = {tunnel.Endpoint}");
        lines.Add($"AllowedIPs = {string.Join(", ", tunnel.AllowedIps)}");
        lines.Add($"PersistentKeepalive = {tunnel.PersistentKeepalive}");
        lines.Add(string.Empty);
        var configuration = string.Join('\n', lines);
        VpnTunnelConfigurationValidator.Validate(configuration);
        return configuration;
    }

    private static byte[] Decode(string value, int maximumBytes)
    {
        try
        {
            var normalized = value
                .Replace('-', '+')
                .Replace('_', '/');
            normalized = (normalized.Length % 4) switch
            {
                0 => normalized,
                2 => normalized + "==",
                3 => normalized + "=",
                _ => throw new FormatException(),
            };
            var decoded = Convert.FromBase64String(normalized);
            if (decoded.Length is < 1 || decoded.Length > maximumBytes)
            {
                Reject("profile_authorization_invalid");
            }

            return decoded;
        }
        catch (FormatException)
        {
            Reject("profile_authorization_invalid");
            throw;
        }
    }

    private static void ValidateWireGuardKey(string value, string errorCode)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            Reject(errorCode);
        }

        try
        {
            if (Convert.FromBase64String(value).Length != 32)
            {
                Reject(errorCode);
            }
        }
        catch (FormatException)
        {
            Reject(errorCode);
        }
    }

    private static void ValidateEndpoint(string value)
    {
        if (ContainsUnsafeText(value, 512) ||
            !Uri.TryCreate($"udp://{value}", UriKind.Absolute, out var endpoint) ||
            endpoint.Port is < 1 or > 65535 ||
            endpoint.UserInfo.Length != 0 ||
            endpoint.Query.Length != 0 ||
            endpoint.Fragment.Length != 0 ||
            endpoint.AbsolutePath != "/" ||
            (IPAddress.TryParse(endpoint.Host, out _) is false &&
             Uri.CheckHostName(endpoint.Host) != UriHostNameType.Dns))
        {
            Reject("profile_endpoint_invalid");
        }
    }

    private static void ValidateCidr(
        string value,
        AddressFamily? expectedFamily,
        string errorCode)
    {
        var parts = value.Split('/');
        if (parts.Length != 2 ||
            !IPAddress.TryParse(parts[0], out var address) ||
            !int.TryParse(parts[1], out var prefix) ||
            expectedFamily is not null &&
            address.AddressFamily != expectedFamily ||
            prefix < 0 ||
            prefix > (address.AddressFamily == AddressFamily.InterNetwork
                ? 32
                : 128))
        {
            Reject(errorCode);
        }
    }

    private static void ValidateList(
        IReadOnlyList<string>? values,
        int maximumCount,
        Action<string> validate,
        string errorCode)
    {
        if (values is null ||
            values.Count is < 1 ||
            values.Count > maximumCount)
        {
            Reject(errorCode);
        }

        foreach (var value in values)
        {
            if (ContainsUnsafeText(value, 256))
            {
                Reject(errorCode);
            }

            validate(value);
        }
    }

    private static bool SafeIdentifier(string value, int maximumLength) =>
        !ContainsUnsafeText(value, maximumLength) &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '-' or '_' or '.');

    private static bool ContainsUnsafeText(string? value, int maximumLength) =>
        string.IsNullOrWhiteSpace(value) ||
        value.Length > maximumLength ||
        value.Any(char.IsControl);

    [DoesNotReturn]
    private static void Reject(string code) =>
        throw new VpnTunnelException(code);

    private sealed record SignedVpnProfilePolicy
    {
        [JsonPropertyName("schema")]
        public string Schema { get; init; } = string.Empty;

        [JsonPropertyName("profile_version")]
        public int ProfileVersion { get; init; }

        [JsonPropertyName("user_id")]
        public string UserId { get; init; } = string.Empty;

        [JsonPropertyName("device_id")]
        public string DeviceId { get; init; } = string.Empty;

        [JsonPropertyName("requested_location_id")]
        public string RequestedLocationId { get; init; } = string.Empty;

        [JsonPropertyName("assigned_location_id")]
        public string AssignedLocationId { get; init; } = string.Empty;

        [JsonPropertyName("routing_mode")]
        public string RoutingMode { get; init; } = string.Empty;

        [JsonPropertyName("bypass_region")]
        public string BypassRegion { get; init; } = string.Empty;

        [JsonPropertyName("routing_policy_version")]
        public string RoutingPolicyVersion { get; init; } = string.Empty;

        [JsonPropertyName("issued_at")]
        public DateTimeOffset IssuedAt { get; init; }

        [JsonPropertyName("expires_at")]
        public DateTimeOffset ExpiresAt { get; init; }

        [JsonPropertyName("tunnel")]
        public SignedTunnelPolicy Tunnel { get; init; } = new();
    }

    private sealed record SignedTunnelPolicy
    {
        [JsonPropertyName("protocol")]
        public string Protocol { get; init; } = string.Empty;

        [JsonPropertyName("endpoint")]
        public string Endpoint { get; init; } = string.Empty;

        [JsonPropertyName("server_public_key")]
        public string ServerPublicKey { get; init; } = string.Empty;

        [JsonPropertyName("preshared_key")]
        public string? PresharedKey { get; init; }

        [JsonPropertyName("assigned_ipv4")]
        public string AssignedIpv4 { get; init; } = string.Empty;

        [JsonPropertyName("dns")]
        public IReadOnlyList<string> Dns { get; init; } = [];

        [JsonPropertyName("allowed_ips")]
        public IReadOnlyList<string> AllowedIps { get; init; } = [];

        [JsonPropertyName("mtu")]
        public int Mtu { get; init; }

        [JsonPropertyName("persistent_keepalive")]
        public int PersistentKeepalive { get; init; }

        [JsonPropertyName("amnezia")]
        public SignedAmneziaPolicy? Amnezia { get; init; }
    }

    private sealed record SignedAmneziaPolicy
    {
        [JsonPropertyName("jc")]
        public ushort? Jc { get; init; }

        [JsonPropertyName("jmin")]
        public ushort? Jmin { get; init; }

        [JsonPropertyName("jmax")]
        public ushort? Jmax { get; init; }

        [JsonPropertyName("s1")]
        public uint? S1 { get; init; }

        [JsonPropertyName("s2")]
        public uint? S2 { get; init; }

        [JsonPropertyName("s3")]
        public uint? S3 { get; init; }

        [JsonPropertyName("s4")]
        public uint? S4 { get; init; }

        [JsonPropertyName("h1")]
        public string? H1 { get; init; }

        [JsonPropertyName("h2")]
        public string? H2 { get; init; }

        [JsonPropertyName("h3")]
        public string? H3 { get; init; }

        [JsonPropertyName("h4")]
        public string? H4 { get; init; }

        [JsonPropertyName("i1")]
        public string? I1 { get; init; }

        [JsonPropertyName("i2")]
        public string? I2 { get; init; }

        [JsonPropertyName("i3")]
        public string? I3 { get; init; }

        [JsonPropertyName("i4")]
        public string? I4 { get; init; }

        [JsonPropertyName("i5")]
        public string? I5 { get; init; }

        public void AppendTo(List<string> lines)
        {
            Append(lines, "Jc", Jc);
            Append(lines, "Jmin", Jmin);
            Append(lines, "Jmax", Jmax);
            Append(lines, "S1", S1);
            Append(lines, "S2", S2);
            Append(lines, "S3", S3);
            Append(lines, "S4", S4);
            Append(lines, "H1", H1);
            Append(lines, "H2", H2);
            Append(lines, "H3", H3);
            Append(lines, "H4", H4);
            Append(lines, "I1", I1);
            Append(lines, "I2", I2);
            Append(lines, "I3", I3);
            Append(lines, "I4", I4);
            Append(lines, "I5", I5);
        }

        private static void Append<T>(
            List<string> lines,
            string name,
            T? value)
        {
            if (value is null)
            {
                return;
            }

            var rendered = value?.ToString();
            if (rendered?.Length == 0)
            {
                return;
            }

            if (ContainsUnsafeText(rendered, 1024))
            {
                Reject("profile_amnezia_parameters_invalid");
            }

            lines.Add($"{name} = {rendered}");
        }
    }
}

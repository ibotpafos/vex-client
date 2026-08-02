using System.Text.Json.Serialization;
using System.Net;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Api;

public sealed record VexUser(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("status")] string Status);

public sealed record VexAuthSession(
    VexUser User,
    string AccessToken,
    DateTimeOffset? ExpiresAt);

public sealed record EmailOtpChallenge(
    string ChallengeId,
    DateTimeOffset? ExpiresAt);

internal sealed record AuthResponse(
    [property: JsonPropertyName("user")] VexUser User,
    [property: JsonPropertyName("session")] AuthSessionPayload Session);

internal sealed record AuthSessionPayload(
    [property: JsonPropertyName("access_token")] string AccessToken,
    [property: JsonPropertyName("expires_at")] DateTimeOffset? ExpiresAt);

internal sealed record EmailOtpChallengeResponse(
    [property: JsonPropertyName("challenge_id")] string ChallengeId,
    [property: JsonPropertyName("expires_at")] DateTimeOffset? ExpiresAt);

public sealed record VpnLocation(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("city")] string City,
    [property: JsonPropertyName("availability")] string Availability,
    [property: JsonPropertyName("healthy_nodes")] int HealthyNodes,
    [property: JsonPropertyName("country_code")] string? CountryCode = null,
    [property: JsonPropertyName("flag_emoji")] string? FlagEmoji = null,
    [property: JsonPropertyName("status")] string? Status = null,
    [property: JsonPropertyName("latency_ms")] double? LatencyMs = null);

public sealed record VpnDevice(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("public_key")] string? PublicKey,
    [property: JsonPropertyName("assigned_ipv4")] string? AssignedIpv4 = null,
    [property: JsonPropertyName("node_id")] string? NodeId = null,
    [property: JsonPropertyName("protocol")] string? Protocol = null,
    [property: JsonPropertyName("protocol_label")] string? ProtocolLabel = null,
    [property: JsonPropertyName("endpoint")] string? Endpoint = null,
    [property: JsonPropertyName("latency_ms")] double? LatencyMs = null,
    [property: JsonPropertyName("provisioning_mode")] string? ProvisioningMode = null,
    [property: JsonPropertyName("client_key_ownership")] string? ClientKeyOwnership = null,
    [property: JsonPropertyName("external_device_id")] string? ExternalDeviceId = null,
    [property: JsonPropertyName("platform")] string? Platform = null,
    [property: JsonPropertyName("app_version")] string? AppVersion = null);

public sealed record ManagedVpnProfileAuthorization(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("algorithm")] string Algorithm,
    [property: JsonPropertyName("payload_base64")] string PayloadBase64,
    [property: JsonPropertyName("signature_base64")] string SignatureBase64)
{
    public VpnProfileAuthorization ToServiceAuthorization() =>
        new(KeyId, Algorithm, PayloadBase64, SignatureBase64);
}

public sealed record ManagedVpnProfile(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("revoked")] bool Revoked,
    [property: JsonPropertyName("rotation_required")] bool RotationRequired,
    [property: JsonPropertyName("authorization")]
        ManagedVpnProfileAuthorization? Authorization,
    [property: JsonPropertyName("unchanged")] bool Unchanged = false);

internal sealed record DeviceIdentityChallengeResponse(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("purpose")] string Purpose);

internal sealed record NativeDeviceRegistrationResponse(
    [property: JsonPropertyName("device")] VpnDevice Device);

public sealed class VexApiException : Exception
{
    public VexApiException(HttpStatusCode statusCode, string code)
        : base(code)
    {
        StatusCode = statusCode;
        Code = code;
    }

    public HttpStatusCode StatusCode { get; }

    public string Code { get; }
}

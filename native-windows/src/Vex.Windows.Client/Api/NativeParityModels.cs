using System.Text.Json.Serialization;

namespace Vex.Windows.Client.Api;

public sealed record ResiliencePolicy(
    [property: JsonPropertyName("policy_version")] string PolicyVersion,
    [property: JsonPropertyName("generated_at")] string GeneratedAt,
    [property: JsonPropertyName("expires_at")] string ExpiresAt,
    [property: JsonPropertyName("signature")] ResiliencePolicySignature Signature,
    [property: JsonPropertyName("probe")] ResilienceProbePolicy Probe,
    [property: JsonPropertyName("candidates")] IReadOnlyList<ResilienceConnectionCandidate> Candidates);

public sealed record ResiliencePolicySignature(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("alg")] string? Alg = null,
    [property: JsonPropertyName("key_id")] string? KeyId = null,
    [property: JsonPropertyName("value")] string? Value = null,
    [property: JsonPropertyName("signed_at")] string? SignedAt = null,
    [property: JsonPropertyName("canonical")] string? Canonical = null);

public sealed record ResilienceProbePolicy(
    [property: JsonPropertyName("connect_timeout_ms")] int ConnectTimeoutMs,
    [property: JsonPropertyName("max_candidates")] int MaxCandidates,
    [property: JsonPropertyName("checks")] IReadOnlyList<string> Checks,
    [property: JsonPropertyName("failure_threshold")] int? FailureThreshold = null,
    [property: JsonPropertyName("recovery_threshold")] int? RecoveryThreshold = null,
    [property: JsonPropertyName("quarantine_ms")] int? QuarantineMs = null,
    [property: JsonPropertyName("failback_hold_ms")] int? FailbackHoldMs = null);

public sealed record ResilienceConnectionCandidate(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("protocol")] string ProtocolName,
    [property: JsonPropertyName("location_id")] string LocationId,
    [property: JsonPropertyName("node_id")] string NodeId,
    [property: JsonPropertyName("endpoint")] string Endpoint,
    [property: JsonPropertyName("health_score")] int HealthScore,
    [property: JsonPropertyName("expires_at")] string ExpiresAt,
    [property: JsonPropertyName("path_id")] string? PathId = null,
    [property: JsonPropertyName("path_kind")] string? PathKind = null,
    [property: JsonPropertyName("entry_node_id")] string? EntryNodeId = null,
    [property: JsonPropertyName("failure_domain")] string? FailureDomain = null,
    [property: JsonPropertyName("priority")] int? Priority = null);

public sealed record BillingPayment(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("subscription_id")] string? SubscriptionId,
    [property: JsonPropertyName("checkout_session_id")] string? CheckoutSessionId,
    [property: JsonPropertyName("plan_id")] string? PlanId,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("amount_minor")] int AmountMinor,
    [property: JsonPropertyName("currency")] string Currency,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("receipt_url")] string? ReceiptUrl,
    [property: JsonPropertyName("failure_reason")] string? FailureReason,
    [property: JsonPropertyName("refunded_amount_minor")] int? RefundedAmountMinor,
    [property: JsonPropertyName("refunded_at")] string? RefundedAt,
    [property: JsonPropertyName("paid_at")] string? PaidAt,
    [property: JsonPropertyName("created_at")] string CreatedAt);

public sealed record VpnDeviceUsage(
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("connection_status")] string? ConnectionStatus,
    [property: JsonPropertyName("connected")] bool? Connected,
    [property: JsonPropertyName("seconds_since_handshake")] int? SecondsSinceHandshake,
    [property: JsonPropertyName("rx_bytes")] long? RxBytes,
    [property: JsonPropertyName("tx_bytes")] long? TxBytes,
    [property: JsonPropertyName("total_bytes")] long? TotalBytes);

internal sealed record VpnDeviceUsageResponse(
    [property: JsonPropertyName("usage")] IReadOnlyList<VpnDeviceUsage>? Usage);

public sealed record VpnConnectionTelemetry(
    string DeviceId,
    int? ProfileVersion,
    string? Protocol,
    string Reason);

public sealed record ClientDiagnosticsReport(
    [property: JsonPropertyName("device_id")] string? DeviceId,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("vpn_state")] string VpnState,
    [property: JsonPropertyName("endpoint")] string? Endpoint,
    [property: JsonPropertyName("dns_ok")] bool DnsOk,
    [property: JsonPropertyName("https_ok")] bool HttpsOk,
    [property: JsonPropertyName("latency_avg_ms")] double? LatencyAverageMs,
    [property: JsonPropertyName("rx_bytes")] long RxBytes,
    [property: JsonPropertyName("tx_bytes")] long TxBytes,
    [property: JsonPropertyName("samples")] IReadOnlyDictionary<string, string> Samples);

public sealed record ClientAppMetadata(
    string Platform,
    string AppVersion,
    int BuildNumber,
    string Channel,
    string CoreVersion,
    string OsVersion,
    string Architecture,
    string ApiClientVersion,
    int ConfigSchemaVersion);

[JsonConverter(typeof(AppUpdateCheckResultJsonConverter))]
public sealed record AppUpdateCheckResult(
    [property: JsonPropertyName("updateAvailable")] bool UpdateAvailable,
    [property: JsonPropertyName("required")] bool Required,
    [property: JsonPropertyName("latestVersion")] string LatestVersion,
    [property: JsonPropertyName("latestBuild")] int LatestBuild,
    [property: JsonPropertyName("minSupportedBuild")] int MinSupportedBuild,
    [property: JsonPropertyName("downloadUrl")] string DownloadUrl,
    [property: JsonPropertyName("currentBuildBlocked")] bool? CurrentBuildBlocked = null,
    [property: JsonPropertyName("minConfigSchemaVersion")] int? MinConfigSchemaVersion = null,
    [property: JsonPropertyName("changelog")] string? Changelog = null,
    [property: JsonPropertyName("checksumSha256")] string? ChecksumSha256 = null,
    [property: JsonPropertyName("signatureUrl")] string? SignatureUrl = null,
    [property: JsonPropertyName("channel")] string? Channel = null,
    [property: JsonPropertyName("reason")] string? Reason = null,
    [property: JsonPropertyName("rolloutPercent")] int? RolloutPercent = null,
    [property: JsonPropertyName("checkedAt")] string? CheckedAt = null,
    [property: JsonPropertyName("delivery")] string? Delivery = null);

[JsonConverter(typeof(AppRemoteConfigJsonConverter))]
public sealed record AppRemoteConfig(
    [property: JsonPropertyName("version")] string? Version,
    [property: JsonPropertyName("signature")] string? Signature,
    [property: JsonPropertyName("releasedAt")] string? ReleasedAt,
    [property: JsonPropertyName("platform")] string? Platform,
    [property: JsonPropertyName("channel")] string? Channel,
    [property: JsonPropertyName("minSupportedBuild")] int? MinSupportedBuild,
    [property: JsonPropertyName("recommendedBuild")] int? RecommendedBuild,
    [property: JsonPropertyName("recommendedVersion")] string? RecommendedVersion,
    [property: JsonPropertyName("coreVersion")] string? CoreVersion,
    [property: JsonPropertyName("configSchemaVersion")] int? ConfigSchemaVersion,
    [property: JsonPropertyName("minConfigSchemaVersion")] int? MinConfigSchemaVersion,
    [property: JsonPropertyName("routingPolicyVersion")] string? RoutingPolicyVersion,
    [property: JsonPropertyName("featureFlags")] IReadOnlyDictionary<string, bool>? FeatureFlags,
    [property: JsonPropertyName("incidentBanner")] string? IncidentBanner);

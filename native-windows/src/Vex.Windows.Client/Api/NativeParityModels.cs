using System.Text.Json.Serialization;

namespace Vex.Windows.Client.Api;

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

internal sealed record SupportSocketTicketResponse(
    [property: JsonPropertyName("ticket")] string? Ticket);

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

public sealed record AppUpdateCheckResult(
    [property: JsonPropertyName("update_available")] bool UpdateAvailable,
    [property: JsonPropertyName("required")] bool Required,
    [property: JsonPropertyName("latest_version")] string LatestVersion,
    [property: JsonPropertyName("latest_build")] int LatestBuild,
    [property: JsonPropertyName("min_supported_build")] int MinSupportedBuild,
    [property: JsonPropertyName("download_url")] string DownloadUrl,
    [property: JsonPropertyName("current_build_blocked")] bool? CurrentBuildBlocked = null,
    [property: JsonPropertyName("min_config_schema_version")] int? MinConfigSchemaVersion = null,
    [property: JsonPropertyName("changelog")] string? Changelog = null,
    [property: JsonPropertyName("checksum_sha256")] string? ChecksumSha256 = null,
    [property: JsonPropertyName("signature_url")] string? SignatureUrl = null,
    [property: JsonPropertyName("channel")] string? Channel = null,
    [property: JsonPropertyName("reason")] string? Reason = null,
    [property: JsonPropertyName("rollout_percent")] int? RolloutPercent = null,
    [property: JsonPropertyName("checked_at")] string? CheckedAt = null);

public sealed record AppRemoteConfig(
    [property: JsonPropertyName("version")] string? Version,
    [property: JsonPropertyName("signature")] string? Signature,
    [property: JsonPropertyName("released_at")] string? ReleasedAt,
    [property: JsonPropertyName("platform")] string? Platform,
    [property: JsonPropertyName("channel")] string? Channel,
    [property: JsonPropertyName("min_supported_build")] int? MinSupportedBuild,
    [property: JsonPropertyName("recommended_build")] int? RecommendedBuild,
    [property: JsonPropertyName("recommended_version")] string? RecommendedVersion,
    [property: JsonPropertyName("core_version")] string? CoreVersion,
    [property: JsonPropertyName("config_schema_version")] int? ConfigSchemaVersion,
    [property: JsonPropertyName("min_config_schema_version")] int? MinConfigSchemaVersion,
    [property: JsonPropertyName("routing_policy_version")] string? RoutingPolicyVersion,
    [property: JsonPropertyName("feature_flags")] IReadOnlyDictionary<string, bool>? FeatureFlags,
    [property: JsonPropertyName("incident_banner")] string? IncidentBanner);

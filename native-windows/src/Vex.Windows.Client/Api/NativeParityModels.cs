using System.Text.Json.Serialization;
using Vex.Windows.Core.Vpn;

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
    [property: JsonPropertyName("samples")] IReadOnlyDictionary<string, string> Samples,
    [property: JsonPropertyName("connection_event")] string? ConnectionEvent = null,
    [property: JsonPropertyName("connect_duration_ms")] long? ConnectDurationMs = null,
    [property: JsonPropertyName("transport_from")] string? TransportFrom = null,
    [property: JsonPropertyName("transport_to")] string? TransportTo = null,
    [property: JsonPropertyName("session_uptime_seconds")] long? SessionUptimeSeconds = null);

public sealed record ClientConnectionTelemetrySnapshot(
    string? ConnectionEvent,
    long? ConnectDurationMs,
    string? TransportFrom,
    string? TransportTo,
    long? SessionUptimeSeconds);

/// Tracks diagnostics fields from observed native tunnel transitions. The
/// tracker deliberately accepts timestamps and the verified profile protocol
/// from its caller so reports describe the operation that actually ran.
public sealed class NativeConnectionTelemetryTracker
{
    private DateTimeOffset? _attemptStartedAt;
    private DateTimeOffset? _connectedAt;
    private string? _attemptKind;
    private string? _currentTransport;
    private string? _connectionEvent;
    private long? _connectDurationMs;
    private string? _transportFrom;
    private string? _transportTo;
    private long? _lastSessionUptimeSeconds;

    public void SetConnectionDesired(
        bool desired,
        VpnConnectionPhase currentPhase,
        DateTimeOffset observedAt)
    {
        if (!desired || currentPhase == VpnConnectionPhase.Connected)
        {
            return;
        }

        _attemptStartedAt = observedAt;
        _attemptKind = _connectedAt is null && _currentTransport is null
            ? "connect"
            : "reconnect";
        _connectionEvent = $"{_attemptKind}_started";
        _connectDurationMs = null;
        _transportFrom = _currentTransport;
        _transportTo = null;
        _lastSessionUptimeSeconds = null;
    }

    public void Observe(
        VpnConnectionPhase previousPhase,
        VpnConnectionSnapshot snapshot,
        bool connectionDesired,
        DateTimeOffset observedAt,
        string? protocol)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var observedTransport = ResolveTransport(
            protocol,
            snapshot.Diagnostics?.Endpoint);

        if (snapshot.Phase == VpnConnectionPhase.Connected)
        {
            if (previousPhase != VpnConnectionPhase.Connected)
            {
                var attemptKind = _attemptKind == "reconnect"
                    ? "reconnect"
                    : "connect";
                _connectionEvent = $"{attemptKind}_succeeded";
                _connectDurationMs = DurationMilliseconds(
                    _attemptStartedAt,
                    observedAt);
                _transportTo = observedTransport;
                _connectedAt = observedAt;
                _attemptStartedAt = null;
                _attemptKind = null;
                _lastSessionUptimeSeconds = 0;
            }

            if (observedTransport != "unknown")
            {
                _currentTransport = observedTransport;
                _transportTo = observedTransport;
            }
            return;
        }

        if (snapshot.Phase == VpnConnectionPhase.Connecting &&
            previousPhase == VpnConnectionPhase.Connected)
        {
            _attemptStartedAt = observedAt;
            _attemptKind = "reconnect";
            _connectionEvent = "reconnect_started";
            _connectDurationMs = null;
            _transportFrom = _currentTransport;
            _transportTo = observedTransport;
            _lastSessionUptimeSeconds = CurrentUptime(observedAt);
            return;
        }

        if (snapshot.Phase is VpnConnectionPhase.Error or
            VpnConnectionPhase.Disconnected)
        {
            if (previousPhase == VpnConnectionPhase.Connected &&
                connectionDesired)
            {
                _connectionEvent = "unexpected_disconnect";
                _connectDurationMs = null;
                _transportFrom = _currentTransport ?? observedTransport;
                _transportTo = null;
                _lastSessionUptimeSeconds = CurrentUptime(observedAt);
            }
            else if (_attemptStartedAt is not null && connectionDesired)
            {
                var attemptKind = _attemptKind == "reconnect"
                    ? "reconnect"
                    : "connect";
                _connectionEvent = $"{attemptKind}_failed";
                _connectDurationMs = DurationMilliseconds(
                    _attemptStartedAt,
                    observedAt);
                _transportTo = observedTransport;
                _lastSessionUptimeSeconds = null;
            }
            else if (!connectionDesired)
            {
                _connectionEvent = null;
                _connectDurationMs = null;
                _transportFrom = _currentTransport;
                _transportTo = null;
                _lastSessionUptimeSeconds = CurrentUptime(observedAt);
            }

            _attemptStartedAt = null;
            _attemptKind = null;
            _connectedAt = null;
            _currentTransport = null;
        }
    }

    public ClientConnectionTelemetrySnapshot Snapshot(
        DateTimeOffset observedAt) =>
        new(
            _connectionEvent,
            _connectDurationMs,
            _transportFrom,
            _transportTo,
            _connectedAt is null
                ? _lastSessionUptimeSeconds
                : CurrentUptime(observedAt));

    public static string ResolveTransport(
        string? protocol,
        string? endpoint)
    {
        var normalizedProtocol = protocol?
            .Trim()
            .ToLowerInvariant();
        if (normalizedProtocol is "openvpn")
        {
            return "openvpn";
        }
        if (normalizedProtocol is "wireguard")
        {
            return "wireguard";
        }
        if (normalizedProtocol is "amneziawg" or "awg" or "awg3")
        {
            return EndpointPort(endpoint) == 443
                ? "awg3_udp443"
                : "awg3";
        }
        if (normalizedProtocol is "awg2")
        {
            return "awg2";
        }
        return "unknown";
    }

    private long? CurrentUptime(DateTimeOffset observedAt) =>
        _connectedAt is null
            ? null
            : Math.Max(
                0,
                (long)Math.Floor(
                    (observedAt - _connectedAt.Value).TotalSeconds));

    private static long? DurationMilliseconds(
        DateTimeOffset? startedAt,
        DateTimeOffset observedAt) =>
        startedAt is null
            ? null
            : Math.Max(
                0,
                (long)Math.Round(
                    (observedAt - startedAt.Value).TotalMilliseconds,
                    MidpointRounding.AwayFromZero));

    private static int? EndpointPort(string? endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            return null;
        }
        var value = endpoint.Trim();
        if (Uri.TryCreate($"udp://{value}", UriKind.Absolute, out var uri) &&
            uri.Port > 0)
        {
            return uri.Port;
        }
        return null;
    }
}

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

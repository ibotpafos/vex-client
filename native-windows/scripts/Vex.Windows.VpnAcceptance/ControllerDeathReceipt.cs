using System.Text.Json;

namespace Vex.Windows.VpnAcceptance;

// Shared by the actual Windows observer and portable negative controls. A
// progress file, a different child, or expiry-driven cleanup cannot qualify.
internal sealed record ControllerDeathReceipt(
    string schema, string request_id, int controller_pid, long controller_start_ticks,
    string harness_sha256, DateTimeOffset ready_at_utc, DateTimeOffset authorization_expires_at_utc,
    bool dns_over_tunnel, bool https_over_tunnel, long uapi_rx_delta, long uapi_tx_delta,
    bool anti_leak_armed, bool physical_tcp_blocked, bool physical_dns_supported, bool physical_dns_blocked)
{
    internal const string Schema = "vex.windows-active-controller-ready.v1";
    internal static readonly TimeSpan ObservationBudget = TimeSpan.FromSeconds(60);

    internal static ControllerDeathReceipt? Parse(ReadOnlyMemory<byte> bytes, string requestId,
        int processId, long startTicks, string imageHash, bool dnsSupported, DateTimeOffset now)
    {
        if (bytes.Length is <= 0 or > 4096 ||
            !Guid.TryParseExact(requestId, "N", out var nonce) || nonce == Guid.Empty ||
            nonce.ToString("N") != requestId || processId <= 0 || startTicks <= 0 ||
            imageHash.Length != 64 || imageHash.Any(character => !char.IsAsciiHexDigit(character) || char.IsLower(character)))
            return null;
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var fields = new HashSet<string>(["schema", "request_id", "controller_pid", "controller_start_ticks",
                "harness_sha256", "ready_at_utc", "authorization_expires_at_utc", "dns_over_tunnel",
                "https_over_tunnel", "uapi_rx_delta", "uapi_tx_delta", "anti_leak_armed", "physical_tcp_blocked",
                "physical_dns_supported", "physical_dns_blocked"], StringComparer.Ordinal);
            foreach (var field in root.EnumerateObject())
                if (!fields.Remove(field.Name)) return null; // Duplicate and extra fields both fail.
            if (fields.Count != 0 ||
                root.GetProperty("schema").GetString() != Schema ||
                root.GetProperty("request_id").GetString() != requestId ||
                !root.GetProperty("controller_pid").TryGetInt32(out var pid) || pid != processId ||
                !root.GetProperty("controller_start_ticks").TryGetInt64(out var ticks) || ticks != startTicks ||
                root.GetProperty("harness_sha256").GetString() != imageHash ||
                !root.GetProperty("ready_at_utc").TryGetDateTimeOffset(out var ready) || ready.Offset != TimeSpan.Zero ||
                ready > now.AddSeconds(1) || ready < now.AddSeconds(-10) ||
                !root.GetProperty("authorization_expires_at_utc").TryGetDateTimeOffset(out var expiry) ||
                expiry.Offset != TimeSpan.Zero || expiry < now + ObservationBudget + TimeSpan.FromSeconds(5) ||
                expiry > ready.AddSeconds(120) ||
                !root.GetProperty("dns_over_tunnel").GetBoolean() ||
                !root.GetProperty("https_over_tunnel").GetBoolean() ||
                !root.GetProperty("uapi_rx_delta").TryGetInt64(out var rx) || rx <= 0 ||
                !root.GetProperty("uapi_tx_delta").TryGetInt64(out var tx) || tx <= 0 ||
                !root.GetProperty("anti_leak_armed").GetBoolean() ||
                !root.GetProperty("physical_tcp_blocked").GetBoolean() ||
                root.GetProperty("physical_dns_supported").GetBoolean() != dnsSupported ||
                root.GetProperty("physical_dns_blocked").GetBoolean() != dnsSupported) return null;
            return new(Schema, requestId, pid, ticks, imageHash, ready, expiry, true, true, rx, tx,
                true, true, dnsSupported, dnsSupported);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException or KeyNotFoundException)
        {
            return null;
        }
    }
}

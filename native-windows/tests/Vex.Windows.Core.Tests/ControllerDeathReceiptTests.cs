using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vex.Windows.VpnAcceptance;

internal static class ControllerDeathReceiptTests
{
    internal static void Run()
    {
        var now = DateTimeOffset.Parse("2026-10-11T12:00:00+00:00");
        var nonce = "0123456789abcdef0123456789abcdef";
        var hash = new string('A', 64);
        var receipt = new ControllerDeathReceipt(ControllerDeathReceipt.Schema, nonce, 71, 639000000000000000,
            hash, now, now.AddSeconds(100), true, true, 33, 41, true, true, false, false);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(receipt);
        var accepted = ControllerDeathReceipt.Parse(bytes, nonce, 71, receipt.controller_start_ticks, hash, false, now);
        Require(accepted == receipt, "Actual positive child evidence was rejected.");
        Require(ControllerDeathReceipt.Parse(JsonSerializer.SerializeToUtf8Bytes(receipt with
            { physical_dns_supported = true, physical_dns_blocked = true }), nonce, 71,
            receipt.controller_start_ticks, hash, true, now) is not null, "Supported protected DNS was rejected.");

        foreach (var mutation in new Action<JsonObject>[]
        {
            root => root["schema"] = "vex.windows-progress.v1",
            root => root["request_id"] = new string('0', 32),
            root => root["controller_pid"] = 72,
            root => root["controller_start_ticks"] = receipt.controller_start_ticks + 1,
            root => root["harness_sha256"] = new string('B', 64),
            root => root["harness_sha256"] = hash.ToLowerInvariant(),
            root => root["ready_at_utc"] = now.AddSeconds(2),
            root => root["ready_at_utc"] = now.AddSeconds(-11),
            root => root["ready_at_utc"] = "2026-10-11T15:00:00+03:00",
            root => root["authorization_expires_at_utc"] = now.AddSeconds(64),
            root => root["authorization_expires_at_utc"] = now.AddSeconds(121),
            root => root["authorization_expires_at_utc"] = now.AddSeconds(-1),
            root => root["dns_over_tunnel"] = false,
            root => root["https_over_tunnel"] = false,
            root => root["uapi_rx_delta"] = 0,
            root => root["uapi_tx_delta"] = -1,
            root => root["uapi_rx_delta"] = "33",
            root => root["anti_leak_armed"] = false,
            root => root["physical_tcp_blocked"] = false,
            root => root["physical_dns_supported"] = true,
            root => root["physical_dns_blocked"] = true,
            root => root["physical_tcp_blocked"] = "true",
            root => root["physical_tcp_blocked"] = null,
            root => root.Remove("https_over_tunnel"),
            root => root["stage"] = "progress",
        })
        {
            var root = JsonNode.Parse(bytes)!.AsObject();
            mutation(root);
            Reject(Encoding.UTF8.GetBytes(root.ToJsonString()));
        }
        Reject(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("\"controller_pid\":71,",
            "\"controller_pid\":71.0,")));
        Reject(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("\"schema\":",
            "\"schema\":\"duplicate\",\"schema\":")));
        Reject("null"u8.ToArray());
        Reject("[]"u8.ToArray());
        Reject("{"u8.ToArray());
        Reject(new byte[4097]);
        Require(ControllerDeathReceipt.Parse(bytes, nonce, 71, receipt.controller_start_ticks, hash, true, now) is null,
            "Unavailable DNS evidence passed a supported-DNS phase.");
        Require(ControllerDeathReceipt.Parse(bytes, new string('0', 32), 71, receipt.controller_start_ticks, hash, false, now) is null,
            "Empty nonce accepted.");
        Require(ControllerDeathReceipt.Parse(bytes, nonce, 0, receipt.controller_start_ticks, hash, false, now) is null,
            "Missing process accepted.");
        Require(ControllerDeathReceipt.Parse(bytes, nonce, 71, receipt.controller_start_ticks, hash.ToLowerInvariant(), false, now) is null,
            "Noncanonical expected image hash accepted.");

        void Reject(byte[] invalid) => Require(ControllerDeathReceipt.Parse(invalid, nonce, 71,
            receipt.controller_start_ticks, hash, false, now) is null,
            "Malformed, stale, wrong-owner, unprotected or expiry-driven evidence was accepted.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

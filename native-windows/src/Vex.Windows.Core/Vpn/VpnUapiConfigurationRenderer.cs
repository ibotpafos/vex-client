using System.Net;
using System.Text;

namespace Vex.Windows.Core.Vpn;

public static class VpnUapiConfigurationRenderer
{
    private static readonly IReadOnlyDictionary<string,string> Names = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
        ["PrivateKey"]="private_key", ["PublicKey"]="public_key", ["PresharedKey"]="preshared_key", ["Endpoint"]="endpoint", ["PersistentKeepalive"]="persistent_keepalive_interval",
        ["Jc"]="jc",["Jmin"]="jmin",["Jmax"]="jmax",["S1"]="s1",["S2"]="s2",["S3"]="s3",["S4"]="s4",["H1"]="h1",["H2"]="h2",["H3"]="h3",["H4"]="h4",
        ["I1"]="i1",["I2"]="i2",["I3"]="i3",["I4"]="i4",["I5"]="i5",["HeaderProtectionKey"]="header_protection_key",["ContentPaddingAddition"]="content_padding_addition",
        ["RekeyAfterTime"]="rekey_after_time",["RekeyTimeout"]="rekey_timeout",["RejectAfterTime"]="reject_after_time",["KeepaliveTimeout"]="keepalive_timeout",["MaxHandshakeAttempts"]="max_handshake_attempts",["RandomTrailers"]="random_trailers",["DisableCookies"]="disable_cookies",
    };

    public static string Render(string configuration, string? literalEndpoint = null) {
        VpnTunnelConfigurationValidator.Validate(configuration);
        var output = new StringBuilder();
        foreach (var raw in configuration.Split('\n')) {
            var line = raw.Trim(); if (line.Length == 0 || line.StartsWith('#')) { continue; }
            if (line.Equals("[Interface]", StringComparison.OrdinalIgnoreCase)) { continue; }
            if (line.Equals("[Peer]", StringComparison.OrdinalIgnoreCase)) { output.AppendLine("replace_peers=true"); continue; }
            var parts = line.Split('=', 2); var name = parts[0].Trim(); var value = parts[1].Trim();
            if (name.Equals("AllowedIPs", StringComparison.OrdinalIgnoreCase)) {
                output.AppendLine("replace_allowed_ips=true");
                foreach (var prefix in value.Split(',')) { output.Append("allowed_ip=").Append(prefix.Trim()).Append('\n'); }
            } else if (Names.TryGetValue(name, out var uapi)) {
                if (name.EndsWith("Key", StringComparison.OrdinalIgnoreCase)) { value = Convert.ToHexString(Convert.FromBase64String(value)).ToLowerInvariant(); }
                if (uapi == "endpoint" && literalEndpoint is not null) { value = literalEndpoint; }
                if (uapi is "random_trailers" or "disable_cookies") { value = value is "on" or "true" or "1" ? "true" : "false"; }
                output.Append(uapi).Append('=').Append(value).Append('\n');
            }
        }
        return output.ToString();
    }
}

using System.Net;
using System.Net.Sockets;

namespace Vex.Windows.Core.Vpn;

// The pinned AWG Windows service enables its own WFP block-all policy for /0,
// which also blocks the independently owned VEX control-plane bypass. Two /1
// prefixes cover exactly the same addresses and are recognized by the vendor's
// default-route monitor, while VEX remains the sole owner of AntiLeak policy.
public static class VpnWindowsRouteMaterializer
{
    public static IReadOnlyList<string> Materialize(IEnumerable<string> allowedIps, bool hasIpv6Address)
    {
        var result = new List<string>();
        foreach (var cidr in allowedIps)
        {
            var parts = cidr.Split('/');
            if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) ||
                !int.TryParse(parts[1], out var prefix) || prefix < 0 ||
                prefix > (address.AddressFamily == AddressFamily.InterNetwork ? 32 : 128))
            {
                throw new VpnTunnelException("profile_allowed_ips_invalid");
            }
            if (address.AddressFamily == AddressFamily.InterNetworkV6 && !hasIpv6Address) { continue; }
            if (prefix == 0)
            {
                result.Add(address.AddressFamily == AddressFamily.InterNetwork ? "0.0.0.0/1" : "::/1");
                result.Add(address.AddressFamily == AddressFamily.InterNetwork ? "128.0.0.0/1" : "8000::/1");
            }
            else { result.Add(cidr); }
        }
        return result.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }
}

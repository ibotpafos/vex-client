using System.Globalization;
using System.Net;

namespace Vex.Windows.Core.Vpn;

public sealed record VpnPeerStatistics(
    DateTimeOffset? LatestHandshakeAt,
    long RxBytes,
    long TxBytes,
    string? Endpoint = null)
{
    // Parse only the configured peer. UAPI responses also contain private keys;
    // never retain or log the response in a diagnostic object.
    public static VpnPeerStatistics Parse(IEnumerable<string> lines, string serverPublicKey)
    {
        string expected;
        try { expected = Convert.ToHexString(Convert.FromBase64String(serverPublicKey)); }
        catch (FormatException) { throw new VpnTunnelException("tunnel_peer_status_invalid"); }
        if (expected.Length != 64)
        {
            throw new VpnTunnelException("tunnel_peer_status_invalid");
        }
        var selected = false;
        var matched = false;
        var completed = false;
        long handshake = 0;
        long rx = 0;
        long tx = 0;
        string? endpoint = null;
        foreach (var line in lines)
        {
            var separator = line.IndexOf('=');
            if (separator < 1) { continue; }
            var name = line[..separator];
            var value = line[(separator + 1)..];
            if (name == "public_key")
            {
                selected = string.Equals(value, expected, StringComparison.OrdinalIgnoreCase);
                if (selected && matched)
                {
                    throw new VpnTunnelException("tunnel_peer_status_invalid");
                }
                matched |= selected;
            }
            else if (name == "errno")
            {
                if (value != "0") { throw new VpnTunnelException("tunnel_peer_status_invalid"); }
                completed = true;
            }
            else if (selected && name == "endpoint")
            {
                // Endpoint metadata is optional. Unsupported UAPI representations
                // cannot seed routing recovery, but do not invalidate peer health.
                endpoint = IPEndPoint.TryParse(value, out var numeric) && numeric.Port > 0
                    ? numeric.ToString() : null;
            }
            else if (selected && name is "last_handshake_time_sec" or "rx_bytes" or "tx_bytes")
            {
                if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number))
                {
                    throw new VpnTunnelException("tunnel_peer_status_invalid");
                }
                switch (name)
                {
                    case "last_handshake_time_sec": handshake = number; break;
                    case "rx_bytes": rx = number; break;
                    case "tx_bytes": tx = number; break;
                }
            }
        }
        if (!matched || !completed)
        {
            throw new VpnTunnelException("tunnel_peer_status_unavailable");
        }
        try
        {
            return new VpnPeerStatistics(
                handshake > 0 ? DateTimeOffset.FromUnixTimeSeconds(handshake) : null,
                rx,
                tx,
                endpoint);
        }
        catch (ArgumentOutOfRangeException)
        {
            throw new VpnTunnelException("tunnel_peer_status_invalid");
        }
    }

    public bool HasFreshHandshake(DateTimeOffset now, TimeSpan maximumAge) =>
        LatestHandshakeAt is not null &&
        LatestHandshakeAt <= now + TimeSpan.FromSeconds(2) &&
        LatestHandshakeAt >= now - maximumAge;
}

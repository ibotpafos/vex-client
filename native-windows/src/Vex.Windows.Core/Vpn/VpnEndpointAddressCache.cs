using System.Net;
using System.Net.Sockets;

namespace Vex.Windows.Core.Vpn;

public sealed record VpnEndpointAddressSnapshot(
    string Endpoint,
    string ServerPublicKey,
    DateTimeOffset ValidUntil,
    IReadOnlyList<string> Addresses);

// Routing metadata only: it never authorizes a profile or changes its endpoint.
// A previous DNS answer is reusable only by the same admitted endpoint/peer and
// only while its signed authorization remains valid.
public sealed class VpnEndpointAddressCache
{
    private readonly object _gate = new();
    private VpnEndpointAddressSnapshot? _snapshot;

    public VpnEndpointAddressSnapshot? Snapshot
    {
        get { lock (_gate) { return _snapshot; } }
    }

    public IReadOnlyList<IPAddress> Get(string endpoint, string? serverPublicKey, DateTimeOffset now)
    {
        lock (_gate)
        {
            if (_snapshot is null || _snapshot.ValidUntil <= now ||
                !string.Equals(_snapshot.Endpoint, endpoint.Trim(), StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(_snapshot.ServerPublicKey, serverPublicKey, StringComparison.Ordinal))
            {
                return [];
            }
            return _snapshot.Addresses.Select(IPAddress.Parse).ToArray();
        }
    }

    public bool Restore(VpnEndpointAddressSnapshot? snapshot, DateTimeOffset now)
    {
        if (snapshot is null || snapshot.Addresses is null || snapshot.Addresses.Count is < 1 or > 16 ||
            snapshot.ValidUntil <= now || snapshot.ValidUntil > now.AddHours(24) ||
            !TryParseEndpoint(snapshot.Endpoint, out _, out _) || !ValidPeer(snapshot.ServerPublicKey))
        {
            return false;
        }
        var addresses = new List<IPAddress>();
        foreach (var value in snapshot.Addresses)
        {
            if (!IPAddress.TryParse(value, out var address) || address.AddressFamily is not
                (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)) { return false; }
            addresses.Add(address);
        }
        return RememberResolved(snapshot.Endpoint, snapshot.ServerPublicKey, addresses, snapshot.ValidUntil, now);
    }

    public bool RememberResolved(string endpoint, string? serverPublicKey, IEnumerable<IPAddress> addresses,
        DateTimeOffset? authorizationExpiresAt, DateTimeOffset now)
    {
        if (!TryParseEndpoint(endpoint, out var host, out _) || !ValidPeer(serverPublicKey) ||
            authorizationExpiresAt is null || authorizationExpiresAt <= now || authorizationExpiresAt > now.AddHours(24))
        {
            return false;
        }
        var numeric = addresses.Where(address => address.AddressFamily is
            AddressFamily.InterNetwork or AddressFamily.InterNetworkV6).Distinct().Take(17).ToArray();
        if (numeric.Length is < 1 or > 16 ||
            IPAddress.TryParse(host, out var literal) && numeric.Any(address => !address.Equals(literal)))
        {
            return false;
        }
        lock (_gate)
        {
            _snapshot = new VpnEndpointAddressSnapshot(endpoint.Trim(), serverPublicKey!, authorizationExpiresAt.Value,
                numeric.Select(address => address.ToString()).ToArray());
        }
        return true;
    }

    public bool ObserveSelectedPeer(string endpoint, string serverPublicKey, string? numericEndpoint,
        DateTimeOffset? authorizationExpiresAt, DateTimeOffset now)
    {
        if (!TryParseEndpoint(endpoint, out var host, out var port) || numericEndpoint is null ||
            !IPEndPoint.TryParse(numericEndpoint, out var selected) || selected.Port != port ||
            IPAddress.TryParse(host, out var literal) && !literal.Equals(selected.Address))
        {
            return false;
        }
        return RememberResolved(endpoint, serverPublicKey, [selected.Address], authorizationExpiresAt, now);
    }

    public static bool TryParseEndpoint(string? endpoint, out string host, out int port)
    {
        host = ""; port = 0;
        if (string.IsNullOrWhiteSpace(endpoint) || endpoint.Length > 512) { return false; }
        var value = endpoint.Trim();
        var separator = value.LastIndexOf(':');
        if (separator < 1 || !int.TryParse(value[(separator + 1)..], out port) || port is < 1 or > 65535)
        {
            return false;
        }
        host = value[..separator];
        if (host.StartsWith('[') && host.EndsWith(']')) { host = host[1..^1]; }
        if (host.Length == 0 || Uri.CheckHostName(host) == UriHostNameType.Unknown) { return false; }
        return !host.Contains(':') || IPAddress.TryParse(host, out _);
    }

    private static bool ValidPeer(string? publicKey)
    {
        if (string.IsNullOrWhiteSpace(publicKey) || publicKey.Length > 64) { return false; }
        try { return Convert.FromBase64String(publicKey).Length == 32; }
        catch (FormatException) { return false; }
    }
}

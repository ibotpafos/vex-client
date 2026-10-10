using System.Collections.ObjectModel;
using System.Net;
using System.Net.Sockets;

namespace Vex.Windows.Core.Vpn;

public sealed record VpnControlPlaneHostAddresses(string Host, IReadOnlyList<string> Addresses);

public sealed record VpnControlPlaneAddressSnapshot(
    int Version,
    IReadOnlyList<string> ConfiguredHosts,
    string Endpoint,
    string ServerPublicKey,
    DateTimeOffset ValidUntil,
    IReadOnlyList<VpnControlPlaneHostAddresses> Entries);

// Numeric routing metadata only. A snapshot cannot admit a profile, introduce a
// new control host, or outlive the authorization that admitted its DNS answers.
public sealed class VpnControlPlaneAddressCache
{
    private const int SnapshotVersion = 1;
    private const int MaximumHosts = 16;
    private const int MaximumAddressesPerHost = 16;
    private static readonly IReadOnlyDictionary<string, IPAddress[]> Empty =
        new ReadOnlyDictionary<string, IPAddress[]>(new Dictionary<string, IPAddress[]>(StringComparer.OrdinalIgnoreCase));
    private readonly object _gate = new();
    private VpnControlPlaneAddressSnapshot? _snapshot;

    public VpnControlPlaneAddressSnapshot? Snapshot
    {
        get { lock (_gate) { return _snapshot; } }
    }

    public bool Restore(VpnControlPlaneAddressSnapshot? snapshot,
        IReadOnlyList<string> configuredHosts, DateTimeOffset now)
    {
        if (snapshot is null || snapshot.Version != SnapshotVersion ||
            !TryNormalizeHosts(configuredHosts, out var hosts) ||
            !TryNormalizeHosts(snapshot.ConfiguredHosts, out var persistedHosts) ||
            !hosts.SequenceEqual(persistedHosts, StringComparer.OrdinalIgnoreCase) ||
            !ValidScope(snapshot.Endpoint, snapshot.ServerPublicKey, snapshot.ValidUntil, now) ||
            snapshot.Entries is null || snapshot.Entries.Count > MaximumHosts)
        {
            return false;
        }
        var entries = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in snapshot.Entries)
        {
            if (entry is null || !TryNormalizeHost(entry.Host, out var host) ||
                !hosts.Contains(host, StringComparer.OrdinalIgnoreCase) || entries.ContainsKey(host) ||
                !TryNormalizeAddresses(entry.Addresses, host, out var addresses))
            {
                return false;
            }
            entries.Add(host, addresses);
        }
        if (hosts.Length != 0 && entries.Count == 0) { return false; }
        var restored = CreateSnapshot(hosts, snapshot.Endpoint, snapshot.ServerPublicKey, snapshot.ValidUntil, entries);
        lock (_gate) { _snapshot = restored; }
        return true;
    }

    public bool Remember(string endpoint, string? serverPublicKey, IReadOnlyList<string> configuredHosts,
        IReadOnlyDictionary<string, IPAddress[]> resolved, DateTimeOffset? authorizationExpiresAt, DateTimeOffset now)
    {
        if (!TryNormalizeHosts(configuredHosts, out var hosts) ||
            !ValidScope(endpoint, serverPublicKey, authorizationExpiresAt, now) ||
            resolved is null || resolved.Count > MaximumHosts)
        {
            return false;
        }
        var fresh = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var answer in resolved)
        {
            if (!TryNormalizeHost(answer.Key, out var host) ||
                !hosts.Contains(host, StringComparer.OrdinalIgnoreCase) || !seen.Add(host) || answer.Value is null)
            {
                return false;
            }
            // An unsuccessful host resolution does not erase a still-admitted answer.
            if (answer.Value.Length == 0) { continue; }
            if (!TryNormalizeAddresses(answer.Value, host, out var addresses)) { return false; }
            fresh.Add(host, addresses);
        }
        lock (_gate)
        {
            var expiry = authorizationExpiresAt.GetValueOrDefault();
            if (Matches(_snapshot, endpoint, serverPublicKey, hosts, now))
            {
                var previous = _snapshot!;
                var retained = false;
                foreach (var entry in previous.Entries)
                {
                    if (fresh.ContainsKey(entry.Host)) { continue; }
                    fresh.Add(entry.Host, entry.Addresses.ToArray());
                    retained = true;
                }
                // The serialized format has one lease. Keeping any previous DNS
                // answer therefore caps the whole snapshot at its previous expiry.
                if (retained && previous.ValidUntil < expiry) { expiry = previous.ValidUntil; }
            }
            if (hosts.Length != 0 && fresh.Count == 0) { return false; }
            _snapshot = CreateSnapshot(hosts, endpoint, serverPublicKey!, expiry, fresh);
            return true;
        }
    }

    public IReadOnlyDictionary<string, IPAddress[]> Get(string endpoint, string? serverPublicKey,
        IReadOnlyList<string> configuredHosts, DateTimeOffset? authorizationExpiresAt, DateTimeOffset now)
    {
        if (!TryNormalizeHosts(configuredHosts, out var hosts) ||
            !ValidScope(endpoint, serverPublicKey, authorizationExpiresAt, now))
        {
            return Empty;
        }
        lock (_gate)
        {
            // Both the original lease and the caller's current signed lease must
            // be live; supplying a newer lease alone cannot renew old answers.
            if (!Matches(_snapshot, endpoint, serverPublicKey, hosts, now)) { return Empty; }
            var result = new Dictionary<string, IPAddress[]>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in _snapshot!.Entries)
            {
                result.Add(entry.Host, entry.Addresses.Select(IPAddress.Parse).ToArray());
            }
            return new ReadOnlyDictionary<string, IPAddress[]>(result);
        }
    }

    private static bool Matches(VpnControlPlaneAddressSnapshot? snapshot, string endpoint, string? peer,
        string[] hosts, DateTimeOffset now) => snapshot is not null && snapshot.ValidUntil > now &&
        string.Equals(snapshot.Endpoint, endpoint.Trim(), StringComparison.OrdinalIgnoreCase) &&
        string.Equals(snapshot.ServerPublicKey, peer, StringComparison.Ordinal) &&
        snapshot.ConfiguredHosts.SequenceEqual(hosts, StringComparer.OrdinalIgnoreCase);

    private static bool ValidScope(string? endpoint, string? peer, DateTimeOffset? expiry, DateTimeOffset now)
    {
        if (!VpnEndpointAddressCache.TryParseEndpoint(endpoint, out _, out _) ||
            string.IsNullOrWhiteSpace(peer) || peer.Length > 64 || expiry is null || expiry <= now ||
            expiry.Value - now > TimeSpan.FromHours(24))
        {
            return false;
        }
        try { return Convert.FromBase64String(peer).Length == 32; }
        catch (FormatException) { return false; }
    }

    private static bool TryNormalizeHosts(IReadOnlyList<string>? values, out string[] hosts)
    {
        hosts = [];
        if (values is null || values.Count > MaximumHosts) { return false; }
        var normalized = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in values)
        {
            if (!TryNormalizeHost(value, out var host)) { return false; }
            normalized.Add(host);
        }
        hosts = normalized.OrderBy(value => value, StringComparer.OrdinalIgnoreCase).ToArray();
        return true;
    }

    private static bool TryNormalizeHost(string? value, out string host)
    {
        host = "";
        if (string.IsNullOrWhiteSpace(value) || value.Length > 253 || value.Any(char.IsControl)) { return false; }
        var normalized = value.Trim();
        if (normalized.StartsWith('[') && normalized.EndsWith(']')) { normalized = normalized[1..^1]; }
        if (IPAddress.TryParse(normalized, out var literal))
        {
            if (literal.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)) { return false; }
            host = literal.ToString();
            return true;
        }
        if (Uri.CheckHostName(normalized) != UriHostNameType.Dns) { return false; }
        host = normalized.TrimEnd('.').ToLowerInvariant();
        return host.Length != 0;
    }

    private static bool TryNormalizeAddresses(IEnumerable<string>? values, string host, out string[] addresses)
    {
        addresses = [];
        if (values is null) { return false; }
        var numeric = new List<IPAddress>();
        foreach (var value in values)
        {
            if (value is null || value.Length > 64 || value.Any(char.IsControl) ||
                !IPAddress.TryParse(value, out var address)) { return false; }
            numeric.Add(address);
            if (numeric.Count > MaximumAddressesPerHost) { return false; }
        }
        return TryNormalizeAddresses(numeric, host, out addresses);
    }

    private static bool TryNormalizeAddresses(IEnumerable<IPAddress> values, string host, out string[] addresses)
    {
        addresses = [];
        var numeric = new HashSet<string>(StringComparer.Ordinal);
        var literalHost = IPAddress.TryParse(host, out var literal);
        foreach (var address in values)
        {
            if (address is null || address.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6) ||
                literalHost && !address.Equals(literal))
            {
                return false;
            }
            numeric.Add(address.ToString());
            if (numeric.Count > MaximumAddressesPerHost) { return false; }
        }
        if (numeric.Count == 0) { return false; }
        addresses = numeric.OrderBy(value => value, StringComparer.Ordinal).ToArray();
        return true;
    }

    private static VpnControlPlaneAddressSnapshot CreateSnapshot(string[] hosts, string endpoint, string peer,
        DateTimeOffset expiry, Dictionary<string, string[]> entries) => new(
            SnapshotVersion, Array.AsReadOnly(hosts), endpoint.Trim(), peer, expiry,
            Array.AsReadOnly(entries.OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase)
                .Select(entry => new VpnControlPlaneHostAddresses(entry.Key, Array.AsReadOnly(entry.Value))).ToArray()));
}

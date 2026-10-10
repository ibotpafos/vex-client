using System.Globalization;
using System.Text.Json;

namespace Vex.Windows.Client.Api;

/// <summary>Persists route health and policies in the application's protected storage.</summary>
public interface IDynamicRouteStore
{
    string? Read(string key);
    void Write(string key, string value);
}

/// <summary>Chooses eligible AWG3 ingress paths using the native macOS routing policy.</summary>
public sealed class DynamicRouteEngine
{
    private readonly object sync = new();
    private readonly IDynamicRouteStore? store;
    private readonly string stateKey;
    private readonly string policyKey;
    private readonly StoredState state;
    private string? cachedPolicy;

    public DynamicRouteEngine(
        IDynamicRouteStore? store = null,
        string stateKey = "native.dynamicRouteState.v1",
        string policyKey = "native.resiliencePolicy.v1")
    {
        this.store = store;
        this.stateKey = stateKey;
        this.policyKey = policyKey;
        state = Deserialize<StoredState>(store?.Read(stateKey)) ?? new StoredState();
        state.Routes ??= new(StringComparer.Ordinal);
        state.PreferredPathByDevice ??= new(StringComparer.Ordinal);
        cachedPolicy = store?.Read(policyKey);
    }

    public void CachePolicy(ResiliencePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (policy.Probe is null || policy.Candidates is null) { return; }
        lock (sync)
        {
            cachedPolicy = JsonSerializer.Serialize(policy);
            store?.Write(policyKey, cachedPolicy);
        }
    }

    public ResiliencePolicy? CachedPolicy(DateTimeOffset utcNow)
    {
        lock (sync)
        {
            var policy = Deserialize<ResiliencePolicy>(cachedPolicy);
            return policy is not null && policy.Probe is not null && policy.Candidates is not null && IsUnexpired(policy.ExpiresAt, utcNow)
                ? policy
                : null;
        }
    }

    public IReadOnlyList<ResilienceConnectionCandidate> OrderedCandidates(
        string deviceId,
        string locationId,
        string? nodeId,
        string? protocol,
        bool hasHeaderProtectionKey,
        ResiliencePolicy policy,
        DateTimeOffset utcNow,
        int awgVersion = 3)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (awgVersion < 3 || !hasHeaderProtectionKey || policy.Probe is null || policy.Candidates is null || !IsUnexpired(policy.ExpiresAt, utcNow))
            return [];

        var normalizedDevice = deviceId.Trim();
        var normalizedLocation = locationId.Trim();
        var normalizedNode = nodeId?.Trim();
        var normalizedProtocol = protocol?.Trim();

        lock (sync)
        {
            var candidates = policy.Candidates.Where(candidate => candidate is not null).Where(candidate =>
                string.Equals(candidate.DeviceId, normalizedDevice, StringComparison.Ordinal) &&
                string.Equals(candidate.LocationId, normalizedLocation, StringComparison.OrdinalIgnoreCase) &&
                !string.IsNullOrWhiteSpace(candidate.Endpoint) &&
                (string.IsNullOrEmpty(normalizedNode) ||
                 string.Equals(candidate.NodeId, normalizedNode, StringComparison.OrdinalIgnoreCase)) &&
                (string.IsNullOrEmpty(normalizedProtocol) ||
                 string.Equals(candidate.ProtocolName, normalizedProtocol, StringComparison.OrdinalIgnoreCase)) &&
                IsUnexpired(candidate.ExpiresAt, utcNow) &&
                (!state.Routes.TryGetValue(candidate.Id, out var route) ||
                 route.QuarantineUntil is null || route.QuarantineUntil <= utcNow)).ToList();

            string? stickyPath = null;
            var failbackHold = TimeSpan.FromMilliseconds(Math.Max(policy.Probe.FailbackHoldMs ?? 120_000, 0));
            if (state.PreferredPathByDevice.TryGetValue(normalizedDevice, out var preferredPath))
            {
                var preferred = candidates.FirstOrDefault(candidate => PathId(candidate) == preferredPath);
                if (preferred is not null &&
                    state.Routes.TryGetValue(preferred.Id, out var preferredState) &&
                    preferredState.LastSuccessAt is { } lastSuccess &&
                    utcNow - lastSuccess < failbackHold)
                    stickyPath = preferredPath;
            }

            var ordered = candidates
                .OrderByDescending(candidate => stickyPath is not null && PathId(candidate) == stickyPath)
                .ThenByDescending(candidate => candidate.Priority ?? 0)
                .ThenByDescending(candidate => candidate.HealthScore)
                .ThenBy(candidate => candidate.Id, StringComparer.Ordinal)
                .ToList();
            var maximum = Math.Max(policy.Probe.MaxCandidates, 1);
            if (ordered.Count <= maximum)
                return ordered;

            // Retain independent ingress providers before filling remaining slots.
            var selected = new List<ResilienceConnectionCandidate>(maximum);
            var selectedIds = new HashSet<string>(StringComparer.Ordinal);
            var domains = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var candidate in ordered)
            {
                if (!domains.Add(FailureDomainKey(candidate)))
                    continue;
                selected.Add(candidate);
                selectedIds.Add(candidate.Id);
                if (selected.Count == maximum)
                    return selected;
            }

            foreach (var candidate in ordered)
            {
                if (!selectedIds.Add(candidate.Id))
                    continue;
                selected.Add(candidate);
                if (selected.Count == maximum)
                    break;
            }
            return selected;
        }
    }

    public void RecordFailure(
        ResilienceConnectionCandidate candidate,
        ResiliencePolicy policy,
        DateTimeOffset utcNow)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(policy);
        lock (sync)
        {
            var route = GetRoute(candidate.Id);
            route.ConsecutiveFailures = (int)Math.Min((long)route.ConsecutiveFailures + 1, int.MaxValue);
            route.ConsecutiveSuccesses = 0;
            route.LastSelectedAt = utcNow;
            if (route.ConsecutiveFailures >= Math.Max(policy.Probe.FailureThreshold ?? 2, 1))
            {
                route.QuarantineUntil = utcNow.AddMilliseconds(Math.Max(policy.Probe.QuarantineMs ?? 30_000, 0));
                if (state.PreferredPathByDevice.TryGetValue(candidate.DeviceId, out var preferred) &&
                    preferred == PathId(candidate))
                    state.PreferredPathByDevice.Remove(candidate.DeviceId);
            }
            PersistState();
        }
    }

    public void RecordSuccess(
        ResilienceConnectionCandidate candidate,
        ResiliencePolicy policy,
        DateTimeOffset utcNow)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(policy);
        lock (sync)
        {
            var route = GetRoute(candidate.Id);
            route.ConsecutiveFailures = 0;
            route.ConsecutiveSuccesses = (int)Math.Min((long)route.ConsecutiveSuccesses + 1, int.MaxValue);
            route.QuarantineUntil = null;
            route.LastSelectedAt = utcNow;
            route.LastSuccessAt = utcNow;
            state.PreferredPathByDevice[candidate.DeviceId] = PathId(candidate);
            PersistState();
        }
    }

    private RouteState GetRoute(string id)
    {
        if (!state.Routes.TryGetValue(id, out var route))
            state.Routes[id] = route = new RouteState();
        return route;
    }

    private void PersistState() => store?.Write(stateKey, JsonSerializer.Serialize(state));

    private static string PathId(ResilienceConnectionCandidate candidate) =>
        string.IsNullOrWhiteSpace(candidate.PathId) ? candidate.Id : candidate.PathId.Trim();

    private static string FailureDomainKey(ResilienceConnectionCandidate candidate)
    {
        if (!string.IsNullOrWhiteSpace(candidate.FailureDomain))
            return "failure-domain:" + candidate.FailureDomain.Trim();
        if (!string.IsNullOrWhiteSpace(candidate.EntryNodeId))
            return "entry:" + candidate.EntryNodeId.Trim();
        return "endpoint:" + candidate.Endpoint;
    }

    private static bool IsUnexpired(string? value, DateTimeOffset utcNow)
    {
        string[] formats =
        [
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
            "yyyy-MM-dd'T'HH:mm:sszzz",
            "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz"
        ];
        return DateTimeOffset.TryParseExact(value, formats, CultureInfo.InvariantCulture,
                   DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var expiresAt) &&
               expiresAt > utcNow;
    }

    private static T? Deserialize<T>(string? json) where T : class
    {
        if (string.IsNullOrWhiteSpace(json))
            return null;
        try
        {
            return JsonSerializer.Deserialize<T>(json);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private sealed class StoredState
    {
        public StoredState() { }
        public Dictionary<string, RouteState> Routes { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, string> PreferredPathByDevice { get; set; } = new(StringComparer.Ordinal);
    }

    private sealed class RouteState
    {
        public RouteState() { }
        public int ConsecutiveFailures { get; set; }
        public int ConsecutiveSuccesses { get; set; }
        public DateTimeOffset? QuarantineUntil { get; set; }
        public DateTimeOffset? LastSelectedAt { get; set; }
        public DateTimeOffset? LastSuccessAt { get; set; }
    }
}

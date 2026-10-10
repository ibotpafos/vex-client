using Vex.Windows.Client.Api;

public static class DynamicRouteEngineTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    public static void Run()
    {
        ScopeAndExpiryNeverLeakOtherDeviceRoutes();
        SuccessfulRelayStaysPreferredUntilHoldExpires();
        FailuresQuarantineAndSuccessResetsTheCounter();
        LimitedCandidatesPreserveFailureDomainDiversity();
        DomainFallbackAndOrderingAreDeterministic();
        ProtectedStoreRestoresHealthAndUnexpiredPolicy();
        InvalidStorageAndExpiryFailClosed();
    }

    private static void ScopeAndExpiryNeverLeakOtherDeviceRoutes()
    {
        var direct = Candidate("direct", priority: 100);
        var policy = Policy(
            direct,
            direct with { Id = "other-device", DeviceId = "device-2" },
            direct with { Id = "other-location", LocationId = "nl" },
            direct with { Id = "other-node", NodeId = "de-old" },
            direct with { Id = "other-protocol", ProtocolName = "wireguard" },
            direct with { Id = "empty-endpoint", Endpoint = " \n" },
            direct with { Id = "expired", ExpiresAt = Timestamp(Now) },
            direct with { Id = "invalid-expiry", ExpiresAt = "tomorrow" });
        var engine = new DynamicRouteEngine();

        Ids(["direct"], engine.OrderedCandidates(" device-1 ", " DE ", " DE-AWG3 ", " AMNEZIAWG ", true, policy, Now));
        Check(Select(engine, policy, awgVersion: 2).Count == 0, "AWG2 must never use AWG3 routes");
        Check(Select(engine, policy, hasHeaderProtectionKey: false).Count == 0, "Header protection is required");
        Check(Select(engine, policy with { ExpiresAt = Timestamp(Now) }).Count == 0, "Policy expiry is exclusive");
        Check(Select(engine, policy with { ExpiresAt = "invalid" }).Count == 0, "Invalid policy expiry is rejected");

        var optionalScope = engine.OrderedCandidates("device-1", "de", null, null, true, policy, Now);
        Check(optionalScope.Any(candidate => candidate.Id == "other-node"), "Absent node does not constrain policy candidates");
        Check(optionalScope.Any(candidate => candidate.Id == "other-protocol"), "Absent protocol matches native optional scope");
    }

    private static void SuccessfulRelayStaysPreferredUntilHoldExpires()
    {
        var direct = Candidate("direct", priority: 100);
        var relay = Candidate("relay", priority: 80, pathId: "relay-path");
        var policy = Policy(relay, direct);
        var engine = new DynamicRouteEngine();

        Ids(["direct", "relay"], Select(engine, policy));
        engine.RecordSuccess(relay, policy, Now);
        Ids(["relay", "direct"], Select(engine, policy, Now.AddSeconds(119)));
        Ids(["direct", "relay"], Select(engine, policy, Now.AddSeconds(120)));
        Ids(["direct", "relay"], Select(engine, policy with
        {
            Probe = policy.Probe with { FailbackHoldMs = -1 }
        }));
    }

    private static void FailuresQuarantineAndSuccessResetsTheCounter()
    {
        var direct = Candidate("direct", priority: 100);
        var relay = Candidate("relay", priority: 80);
        var policy = Policy(direct, relay);
        var engine = new DynamicRouteEngine();

        engine.RecordSuccess(relay, policy, Now);
        engine.RecordFailure(relay, policy, Now.AddSeconds(1));
        Check(Select(engine, policy, Now.AddSeconds(1)).First().Id == "relay", "First failure retains sticky route");
        engine.RecordFailure(relay, policy, Now.AddSeconds(2));
        Ids(["direct"], Select(engine, policy, Now.AddSeconds(31)));
        Ids(["direct", "relay"], Select(engine, policy, Now.AddSeconds(32)));

        engine.RecordSuccess(relay, policy, Now.AddSeconds(33));
        engine.RecordFailure(relay, policy, Now.AddSeconds(34));
        Check(Select(engine, policy, Now.AddSeconds(34)).First().Id == "relay", "Success resets the failure count");
        engine.RecordFailure(relay, policy, Now.AddSeconds(35));
        Ids(["direct"], Select(engine, policy, Now.AddSeconds(36)));
        engine.RecordSuccess(relay, policy, Now.AddSeconds(36));
        Check(Select(engine, policy, Now.AddSeconds(36)).First().Id == "relay", "Success immediately clears quarantine");

        var immediate = policy with { Probe = policy.Probe with { FailureThreshold = 0, QuarantineMs = 0 } };
        engine.RecordFailure(relay, immediate, Now.AddSeconds(37));
        Ids(["direct", "relay"], Select(engine, immediate, Now.AddSeconds(37)));
    }

    private static void LimitedCandidatesPreserveFailureDomainDiversity()
    {
        var direct = Candidate("direct", priority: 100, entryNodeId: "de-awg3");
        var relayLow = Candidate("relay-low", priority: 80, domain: "asn:9123");
        var relayHigh = Candidate("relay-high", priority: 90, domain: " ASN:9123 ");
        var independent = Candidate("independent", priority: 70, domain: "asn:64501");
        var policy = Policy(relayLow, direct, relayHigh, independent);

        Ids(["direct", "relay-high", "independent"], Select(new DynamicRouteEngine(), policy));
        var engine = new DynamicRouteEngine();
        engine.RecordSuccess(relayLow, policy, Now);
        Ids(["relay-low", "direct", "independent"], Select(engine, policy));
        var single = policy with { Probe = policy.Probe with { MaxCandidates = 0 } };
        Ids(["relay-low"], Select(engine, single));
    }

    private static void DomainFallbackAndOrderingAreDeterministic()
    {
        var policy = Policy(
            Candidate("z", priority: 90, entryNodeId: " NODE-A "),
            Candidate("a", priority: 90, entryNodeId: "node-a"),
            Candidate("b", priority: 90, health: 99, entryNodeId: "node-a"),
            Candidate("independent", priority: 70, entryNodeId: "node-b"));
        Ids(["a", "independent", "z"], Select(new DynamicRouteEngine(), policy));

        var endpointFallback = policy with
        {
            Probe = policy.Probe with { MaxCandidates = 2 },
            Candidates =
            [
                Candidate("primary", priority: 100, endpoint: "EDGE.EXAMPLE:5000"),
                Candidate("duplicate", priority: 90, endpoint: "edge.example:5000"),
                Candidate("independent", priority: 50, endpoint: "other.example:5000")
            ]
        };
        Ids(["primary", "independent"], Select(new DynamicRouteEngine(), endpointFallback));
    }

    private static void ProtectedStoreRestoresHealthAndUnexpiredPolicy()
    {
        var store = new MemoryStore();
        var direct = Candidate("direct", priority: 100);
        var relay = Candidate("relay", priority: 80);
        var policy = Policy(direct, relay);
        var engine = new DynamicRouteEngine(store);
        engine.CachePolicy(policy);
        engine.RecordSuccess(relay, policy, Now);
        engine.RecordFailure(direct, policy, Now);
        engine.RecordFailure(direct, policy, Now);

        var restored = new DynamicRouteEngine(store);
        Ids(["relay"], Select(restored, policy, Now.AddSeconds(1)));
        Ids(["relay", "direct"], Select(restored, policy, Now.AddSeconds(30)));
        Ids(["direct", "relay"], Select(restored, policy, Now.AddSeconds(120)));
        Check(restored.CachedPolicy(Now.AddSeconds(60))?.PolicyVersion == "test-v1", "Live policy survives restart");
        Check(restored.CachedPolicy(Now.AddSeconds(600)) is null, "Expired cache is never returned");

        engine.CachePolicy(policy with { ExpiresAt = Now.AddMinutes(5).ToOffset(TimeSpan.FromHours(3)).ToString("O") });
        Check(new DynamicRouteEngine(store).CachedPolicy(Now) is not null, "Fractional offset ISO8601 expiry is supported");
    }

    private static void InvalidStorageAndExpiryFailClosed()
    {
        var store = new MemoryStore();
        store.Write("native.dynamicRouteState.v1", "{broken-json");
        store.Write("native.resiliencePolicy.v1", "{broken-json");
        var engine = new DynamicRouteEngine(store);
        var policy = Policy(Candidate("direct"));
        Ids(["direct"], Select(engine, policy));
        Check(engine.CachedPolicy(Now) is null, "Malformed cached policy is ignored");
        engine.CachePolicy(policy with { ExpiresAt = "2027-01-15" });
        Check(engine.CachedPolicy(Now) is null, "A calendar date cannot masquerade as an ISO8601 policy deadline");
    }

    private static IReadOnlyList<ResilienceConnectionCandidate> Select(
        DynamicRouteEngine engine,
        ResiliencePolicy policy,
        DateTimeOffset? now = null,
        bool hasHeaderProtectionKey = true,
        int awgVersion = 3) =>
        engine.OrderedCandidates("device-1", "de", "de-awg3", "amneziawg",
            hasHeaderProtectionKey, policy, now ?? Now, awgVersion);

    private static ResiliencePolicy Policy(params ResilienceConnectionCandidate[] candidates) => new(
        PolicyVersion: "test-v1",
        GeneratedAt: Timestamp(Now),
        ExpiresAt: Timestamp(Now.AddSeconds(600)),
        Signature: new("signed", "Ed25519", "test", "signature", Timestamp(Now)),
        Probe: new(ConnectTimeoutMs: 2_500, MaxCandidates: 3, Checks: ["tunnel"],
            FailureThreshold: 2, RecoveryThreshold: 2, QuarantineMs: 30_000, FailbackHoldMs: 120_000),
        Candidates: candidates);

    private static ResilienceConnectionCandidate Candidate(
        string id,
        int priority = 100,
        int health = 100,
        string? pathId = null,
        string? entryNodeId = null,
        string? domain = null,
        string? endpoint = null) => new(
        Id: id,
        PathId: pathId ?? id,
        PathKind: "direct",
        EntryNodeId: entryNodeId,
        FailureDomain: domain,
        Priority: priority,
        DeviceId: "device-1",
        ProtocolName: "amneziawg",
        LocationId: "de",
        NodeId: "de-awg3",
        Endpoint: endpoint ?? id + ".example:51821",
        HealthScore: health,
        ExpiresAt: Timestamp(Now.AddSeconds(600)));

    private static string Timestamp(DateTimeOffset value) => value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

    private static void Ids(string[] expected, IReadOnlyList<ResilienceConnectionCandidate> actual) =>
        Check(expected.SequenceEqual(actual.Select(candidate => candidate.Id)),
            $"Expected routes {string.Join(',', expected)}; got {string.Join(',', actual.Select(candidate => candidate.Id))}");

    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private sealed class MemoryStore : IDynamicRouteStore
    {
        private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);
        public string? Read(string key) => values.GetValueOrDefault(key);
        public void Write(string key, string value) => values[key] = value;
    }
}

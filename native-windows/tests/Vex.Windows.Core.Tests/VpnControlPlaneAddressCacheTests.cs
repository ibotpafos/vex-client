using System.Net;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

internal static class VpnControlPlaneAddressCacheTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
    private static readonly string Peer = Convert.ToBase64String(Enumerable.Repeat((byte)1, 32).ToArray());
    private static readonly string OtherPeer = Convert.ToBase64String(Enumerable.Repeat((byte)2, 32).ToArray());
    private static readonly string[] Hosts = ["api.example.test", "auth.example.test"];
    private const string Endpoint = "vpn.example.test:443";

    public static readonly (string Name, Action Run)[] All =
    [
        ("Control-plane numeric routing survives JSON persistence and offline service restart", SnapshotSurvivesOfflineRestart),
        ("Control-plane routing requires the exact endpoint, peer, host set and live signed leases", ScopeAndLeaseBindingsAreExact),
        ("Malformed control-plane snapshots preserve the currently admitted routing cache", InvalidSnapshotsPreserveMapping),
        ("Control-plane DNS admission refuses unknown hosts and unbounded or malformed answers", FreshAnswersAreBoundedAndConfigured),
        ("Partial DNS success preserves only still-live control hosts in the same signed scope", PartialAnswersRetainScopedFallback),
        ("Partial lease renewal cannot extend retained control-plane DNS answers", PartialRenewalNeverExtendsOldAnswers),
        ("A shorter fresh authorization caps all retained control-plane routing answers", ShorterFreshLeaseCapsSnapshot),
        ("Empty control-plane configuration is valid and admitted routing state is defensive", EmptyConfigurationAndDefensiveState),
        ("Configured numeric control hosts accept only their literal address within cache bounds", NumericHostsAndMaximumBounds),
    ];

    private static Dictionary<string, IPAddress[]> Answers(params (string Host, string[] Addresses)[] entries) =>
        entries.ToDictionary(entry => entry.Host, entry => entry.Addresses.Select(IPAddress.Parse).ToArray(), StringComparer.Ordinal);

    private static VpnControlPlaneAddressCache AdmittedCache()
    {
        var cache = new VpnControlPlaneAddressCache();
        Require(cache.Remember(Endpoint, Peer, Hosts,
            Answers((Hosts[0], ["192.0.2.1", "2001:db8::1", "192.0.2.1"]), (Hosts[1], ["192.0.2.2"])),
            Now.AddMinutes(10), Now), "A valid signed control-plane scope was rejected.");
        return cache;
    }

    private static IReadOnlyDictionary<string, IPAddress[]> Get(VpnControlPlaneAddressCache cache,
        DateTimeOffset? now = null, DateTimeOffset? expiry = null) =>
        cache.Get(Endpoint, Peer, Hosts, expiry ?? Now.AddMinutes(10), now ?? Now);

    private static void SnapshotSurvivesOfflineRestart()
    {
        var online = AdmittedCache();
        var serialized = JsonSerializer.Serialize(online.Snapshot);
        var persisted = JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(serialized);
        var restarted = new VpnControlPlaneAddressCache();
        Require(restarted.Restore(persisted, [" AUTH.EXAMPLE.TEST. ", "API.EXAMPLE.TEST", "api.example.test"], Now.AddMinutes(1)),
            "A normalized configured-host set could not restore admitted numeric routing.");
        var offline = restarted.Get(Endpoint, Peer, Hosts, Now.AddMinutes(10), Now.AddMinutes(1));
        Require(offline.Count == 2 && offline[Hosts[0]].Select(address => address.ToString()).Order().SequenceEqual(
            new[] { "192.0.2.1", "2001:db8::1" }.Order()) && offline[Hosts[1]].Single().ToString() == "192.0.2.2",
            "JSON restart lost numeric API/auth routes or retained duplicate DNS addresses.");
        var restoredSnapshot = restarted.Snapshot!;
        Require(restoredSnapshot.Version == 1 && restoredSnapshot.ConfiguredHosts.SequenceEqual(Hosts),
            "Restored routing scope was not sanitized to its bounded canonical host set.");
        Require(!new VpnControlPlaneAddressCache().Restore(persisted, Hosts, Now.AddMinutes(10)),
            "Offline restart revived routing metadata after its original signed lease.");
    }

    private static void ScopeAndLeaseBindingsAreExact()
    {
        var cache = AdmittedCache();
        Require(cache.Get(" VPN.EXAMPLE.TEST:443 ", Peer, [Hosts[1].ToUpperInvariant(), Hosts[0]],
            Now.AddMinutes(10), Now).Count == 2, "Canonical hostname comparison changed the admitted routing scope.");
        foreach (var endpoint in new[] { "other.example.test:443", "vpn.example.test:444", "192.0.2.1:443" })
        {
            Require(cache.Get(endpoint, Peer, Hosts, Now.AddMinutes(10), Now).Count == 0,
                "Control-plane cache crossed the signed endpoint or port boundary.");
        }
        foreach (var peer in new string?[] { null, "", "invalid", OtherPeer })
        {
            Require(cache.Get(Endpoint, peer, Hosts, Now.AddMinutes(10), Now).Count == 0,
                "Control-plane cache crossed the configured server identity boundary.");
        }
        foreach (var hosts in new string[][] { [], [Hosts[0]], [Hosts[0], "other.example.test"], [.. Hosts, "other.example.test"] })
        {
            Require(cache.Get(Endpoint, Peer, hosts, Now.AddMinutes(10), Now).Count == 0,
                "Control-plane cache crossed the current configured-host set.");
        }
        foreach (var expiry in new DateTimeOffset?[] { null, Now, Now.AddTicks(-1), Now.AddHours(24).AddTicks(1) })
        {
            Require(cache.Get(Endpoint, Peer, Hosts, expiry, Now).Count == 0,
                "Missing, expired or unbounded current signed authorization admitted cached routes.");
        }
        Require(Get(cache, Now.AddMinutes(1), Now.AddMinutes(2)).Count == 2 &&
            Get(cache, Now.AddMinutes(2), Now.AddMinutes(2)).Count == 0,
            "A shorter current signed lease failed to limit reuse at its expiry boundary.");
        Require(Get(cache, Now.AddMinutes(10).AddTicks(-1), Now.AddMinutes(30)).Count == 2 &&
            Get(cache, Now.AddMinutes(10), Now.AddMinutes(30)).Count == 0,
            "A newer signed lease extended the original cached answer authorization.");
    }

    private static void InvalidSnapshotsPreserveMapping()
    {
        var cache = AdmittedCache();
        var original = cache.Snapshot!;
        var malformed = new VpnControlPlaneAddressSnapshot?[]
        {
            null,
            original with { Version = 0 },
            original with { Version = 2 },
            original with { Endpoint = "vpn.example.test:0" },
            original with { ServerPublicKey = "invalid" },
            original with { ValidUntil = Now },
            original with { ValidUntil = Now.AddHours(24).AddTicks(1) },
            original with { ConfiguredHosts = null! },
            original with { ConfiguredHosts = ["api.example.test", "other.example.test"] },
            original with { Entries = null! },
            original with { Entries = [] },
            original with { Entries = [null!] },
            original with { Entries = [new("unknown.example.test", ["192.0.2.99"])] },
            original with { Entries = [new(Hosts[0], null!)] },
            original with { Entries = [new(Hosts[0], [])] },
            original with { Entries = [new(Hosts[0], ["not-numeric"])] },
            original with { Entries = [new(Hosts[0], ["192.0.2.1:443"])] },
            original with { Entries = [new(Hosts[0], ["192.0.2.1"]), new(Hosts[0].ToUpperInvariant(), ["192.0.2.2"])] },
            original with { Entries = [new(Hosts[0], Enumerable.Range(1, 17).Select(index => $"192.0.2.{index}").ToArray())] },
            original with { Entries = Enumerable.Range(1, 17).Select(index => new VpnControlPlaneHostAddresses($"host-{index}.example.test", ["192.0.2.1"])).ToArray() },
        };
        foreach (var snapshot in malformed)
        {
            Require(!cache.Restore(snapshot, Hosts, Now), "Malformed persisted control-plane routing was accepted.");
            Require(ReferenceEquals(cache.Snapshot, original) && Get(cache).Count == 2,
                "Failed restore replaced the currently admitted control-plane mapping.");
        }
        Require(!cache.Restore(original, [Hosts[0]], Now) && ReferenceEquals(cache.Snapshot, original),
            "A valid snapshot crossed a changed live control-plane configuration.");
    }

    private static void FreshAnswersAreBoundedAndConfigured()
    {
        var cache = AdmittedCache();
        var original = cache.Snapshot;
        foreach (var resolved in new IReadOnlyDictionary<string, IPAddress[]>[]
        {
            null!,
            new Dictionary<string, IPAddress[]> { [Hosts[0]] = null! },
            new Dictionary<string, IPAddress[]> { [Hosts[0]] = [null!] },
            Answers(("unknown.example.test", ["192.0.2.99"])),
            Answers((Hosts[0], ["192.0.2.1"]), (Hosts[0].ToUpperInvariant(), ["192.0.2.2"])),
            Answers((Hosts[0], Enumerable.Range(1, 17).Select(index => $"192.0.2.{index}").ToArray())),
            Enumerable.Range(1, 17).ToDictionary(index => $"host-{index}.example.test", _ => new[] { IPAddress.Parse("192.0.2.1") }),
        })
        {
            Require(!cache.Remember(Endpoint, Peer, Hosts, resolved, Now.AddMinutes(30), Now),
                "Unconfigured, ambiguous, malformed or oversized DNS results entered persisted routing metadata.");
            Require(ReferenceEquals(cache.Snapshot, original), "Failed DNS admission changed the currently admitted snapshot.");
        }
        foreach (var hosts in new IReadOnlyList<string>[]
        {
            null!, [""], ["https://api.example.test"], ["api.example.test\n"], [new string('a', 254)],
            Enumerable.Range(1, 17).Select(index => $"host-{index}.example.test").ToArray(),
        })
        {
            Require(!cache.Remember(Endpoint, Peer, hosts, new Dictionary<string, IPAddress[]>(), Now.AddMinutes(10), Now),
                "Malformed or oversized configured host sets admitted routing metadata.");
        }
        foreach (var expiry in new DateTimeOffset?[] { null, Now, Now.AddMinutes(-1), Now.AddHours(24).AddTicks(1) })
        {
            Require(!cache.Remember(Endpoint, Peer, Hosts, Answers((Hosts[0], ["192.0.2.3"])), expiry, Now),
                "An unsigned, expired or unbounded lease admitted fresh control-plane answers.");
        }
        Require(!cache.Remember(Endpoint, "invalid", Hosts, Answers((Hosts[0], ["192.0.2.3"])), Now.AddMinutes(10), Now) &&
            !cache.Remember("vpn.example.test:0", Peer, Hosts, Answers((Hosts[0], ["192.0.2.3"])), Now.AddMinutes(10), Now) &&
            ReferenceEquals(cache.Snapshot, original), "Malformed peer/endpoint scope replaced admitted control-plane routes.");
    }

    private static void PartialAnswersRetainScopedFallback()
    {
        var cache = AdmittedCache();
        Require(cache.Remember(Endpoint, Peer, Hosts,
            Answers((Hosts[0].ToUpperInvariant(), ["192.0.2.3"]), (Hosts[1], [])), Now.AddMinutes(30), Now.AddMinutes(1)),
            "Partial fresh DNS success could not preserve the admitted offline host.");
        Require(Get(cache, Now.AddMinutes(1), Now.AddMinutes(30))[Hosts[0]].Single().ToString() == "192.0.2.3" &&
            Get(cache, Now.AddMinutes(1), Now.AddMinutes(30))[Hosts[1]].Single().ToString() == "192.0.2.2" &&
            cache.Snapshot!.ValidUntil == Now.AddMinutes(10), "Partial merge lost the fresh answer or extended a retained old answer.");
        Require(cache.Remember(Endpoint, Peer, Hosts, new Dictionary<string, IPAddress[]>(), Now.AddMinutes(30), Now.AddMinutes(2)) &&
            cache.Snapshot!.ValidUntil == Now.AddMinutes(10), "An entirely offline refresh erased or renewed existing admitted DNS answers.");

        foreach (var changedScope in new[]
        {
            (Endpoint: "other.example.test:443", Peer, Hosts),
            (Endpoint, Peer: OtherPeer, Hosts),
            (Endpoint, Peer, Hosts: new[] { Hosts[0], Hosts[1], "extra.example.test" }),
        })
        {
            var scoped = AdmittedCache();
            Require(scoped.Remember(changedScope.Endpoint, changedScope.Peer, changedScope.Hosts,
                Answers((Hosts[0], ["192.0.2.3"])), Now.AddMinutes(30), Now.AddMinutes(1)), "A new signed scope rejected its own fresh DNS answer.");
            var answers = scoped.Get(changedScope.Endpoint, changedScope.Peer, changedScope.Hosts, Now.AddMinutes(30), Now.AddMinutes(1));
            Require(answers.Count == 1 && !answers.ContainsKey(Hosts[1]), "Partial refresh retained DNS answers from another scope.");
        }
    }

    private static void PartialRenewalNeverExtendsOldAnswers()
    {
        var cache = AdmittedCache();
        Require(cache.Remember(Endpoint, Peer, Hosts, Answers((Hosts[0], ["192.0.2.3"])), Now.AddMinutes(30), Now.AddMinutes(1)),
            "The first partial renewal was rejected.");
        Require(cache.Remember(Endpoint, Peer, Hosts, Answers((Hosts[1], ["192.0.2.4"])), Now.AddMinutes(40), Now.AddMinutes(2)) &&
            cache.Snapshot!.ValidUntil == Now.AddMinutes(10), "Successive partial updates extended a retained answer's original lease.");
        Require(Get(cache, Now.AddMinutes(10), Now.AddMinutes(40)).Count == 0,
            "Previously admitted DNS answers survived their original authorization deadline.");
        Require(cache.Remember(Endpoint, Peer, Hosts, Answers((Hosts[0], ["192.0.2.5"])), Now.AddMinutes(30), Now.AddMinutes(11)) &&
            Get(cache, Now.AddMinutes(11), Now.AddMinutes(30)).Count == 1,
            "A fresh answer after expiration revived a stale answer for an unresolved host.");
        Require(cache.Remember(Endpoint, Peer, Hosts,
            Answers((Hosts[0], ["192.0.2.6"]), (Hosts[1], ["192.0.2.7"])), Now.AddMinutes(40), Now.AddMinutes(12)) &&
            cache.Snapshot!.ValidUntil == Now.AddMinutes(40), "A complete fresh replacement could not use its own signed lease.");
    }

    private static void ShorterFreshLeaseCapsSnapshot()
    {
        var cache = AdmittedCache();
        Require(cache.Remember(Endpoint, Peer, Hosts, Answers((Hosts[0], ["192.0.2.3"])), Now.AddMinutes(2), Now.AddMinutes(1)) &&
            cache.Snapshot!.ValidUntil == Now.AddMinutes(2), "A shorter fresh lease did not cap retained offline routes.");
        Require(Get(cache, Now.AddMinutes(2), Now.AddMinutes(30)).Count == 0,
            "A later longer lease revived answers capped by a shorter admitted authorization.");
        var restarted = new VpnControlPlaneAddressCache();
        Require(!restarted.Restore(cache.Snapshot, Hosts, Now.AddMinutes(2)), "Restart removed a persisted shortened lease boundary.");
    }

    private static void EmptyConfigurationAndDefensiveState()
    {
        var empty = new VpnControlPlaneAddressCache();
        Require(empty.Remember(Endpoint, Peer, [], new Dictionary<string, IPAddress[]>(), Now.AddMinutes(10), Now),
            "An empty configured control-plane set was rejected.");
        var emptySnapshot = empty.Snapshot!;
        Require(emptySnapshot.ConfiguredHosts.Count == 0 && emptySnapshot.Entries.Count == 0 &&
            empty.Get(Endpoint, Peer, [], Now.AddMinutes(10), Now).Count == 0, "An empty configured control-plane set was rejected.");
        var restarted = new VpnControlPlaneAddressCache();
        Require(restarted.Restore(JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(JsonSerializer.Serialize(empty.Snapshot)), [], Now),
            "A valid empty control-plane snapshot could not survive restart.");
        Require(!empty.Remember(Endpoint, Peer, [], Answers(("unknown.example.test", ["192.0.2.99"])), Now.AddMinutes(10), Now),
            "An empty configuration admitted an arbitrary DNS exception.");

        var addresses = new[] { IPAddress.Parse("192.0.2.1") };
        var hosts = new[] { Hosts[0] };
        var cache = new VpnControlPlaneAddressCache();
        Require(cache.Remember(Endpoint, Peer, hosts, new Dictionary<string, IPAddress[]> { [hosts[0]] = addresses }, Now.AddMinutes(10), Now),
            "A valid defensive-state fixture was rejected.");
        addresses[0] = IPAddress.Loopback;
        hosts[0] = "unknown.example.test";
        var admitted = cache.Get(Endpoint, Peer, [Hosts[0]], Now.AddMinutes(10), Now);
        admitted[Hosts[0]][0] = IPAddress.Loopback;
        var admittedSnapshot = cache.Snapshot!;
        Require(admittedSnapshot.ConfiguredHosts.Single() == Hosts[0] &&
            cache.Get(Endpoint, Peer, [Hosts[0]], Now.AddMinutes(10), Now)[Hosts[0]].Single().ToString() == "192.0.2.1",
            "Caller mutation altered protected configured hosts or numeric recovery addresses.");
        Require(admittedSnapshot.ConfiguredHosts is IList<string> configured && configured.IsReadOnly &&
            admittedSnapshot.Entries is IList<VpnControlPlaneHostAddresses> entries && entries.IsReadOnly &&
            admittedSnapshot.Entries.Single().Addresses is IList<string> numeric && numeric.IsReadOnly,
            "Exposed snapshot collections allow mutation of admitted routing state.");
    }

    private static void NumericHostsAndMaximumBounds()
    {
        var cache = new VpnControlPlaneAddressCache();
        string[] literalHosts = ["192.0.2.1", "2001:db8::1"];
        Require(cache.Remember(Endpoint, Peer, literalHosts,
            Answers((literalHosts[0], [literalHosts[0]]), (literalHosts[1], [literalHosts[1]])), Now.AddHours(24), Now),
            "Valid literal control-plane addresses or the maximum signed lease were rejected.");
        var original = cache.Snapshot;
        Require(!cache.Remember(Endpoint, Peer, literalHosts, Answers((literalHosts[0], ["192.0.2.99"])), Now.AddHours(24), Now) &&
            ReferenceEquals(cache.Snapshot, original), "A configured literal control host admitted an unrelated numeric address.");
        Require(!cache.Restore(original! with { Entries = [new(literalHosts[0], ["192.0.2.99"])] }, literalHosts, Now),
            "Persisted literal control-plane scope admitted an unrelated numeric address.");
        var hosts = Enumerable.Range(1, 16).Select(index => $"host-{index}.example.test").ToArray();
        var addresses = Enumerable.Range(1, 16).Select(index => IPAddress.Parse($"192.0.2.{index}")).ToArray();
        var resolved = hosts.ToDictionary(host => host, _ => addresses.Concat(addresses).ToArray());
        Require(cache.Remember(Endpoint, Peer, hosts, resolved, Now.AddMinutes(10), Now),
            "The maximum bounded cache rejected valid hosts and unique addresses.");
        var boundedSnapshot = cache.Snapshot!;
        Require(boundedSnapshot.Entries.Count == 16 && boundedSnapshot.Entries.All(entry => entry.Addresses.Count == 16),
            "The maximum bounded cache rejected valid hosts or failed to deduplicate numeric DNS answers.");
        var restarted = new VpnControlPlaneAddressCache();
        Require(restarted.Restore(cache.Snapshot, hosts.Reverse().ToArray(), Now) &&
            restarted.Get(Endpoint, Peer, hosts, Now.AddMinutes(10), Now).Count == 16,
            "A maximum-sized sanitized routing snapshot could not be safely restored.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}

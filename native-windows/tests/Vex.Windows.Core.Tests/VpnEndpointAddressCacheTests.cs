using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

internal static class VpnEndpointAddressCacheTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
    private static readonly string Peer = Convert.ToBase64String(Enumerable.Repeat((byte)1, 32).ToArray());
    private static readonly string OtherPeer = Convert.ToBase64String(Enumerable.Repeat((byte)2, 32).ToArray());
    private const string Endpoint = "vpn.example.test:443";

    public static readonly (string Name, Action Run)[] All =
    [
        ("Endpoint routing cache binds the admitted hostname, port, peer and lease", AdmissionBindingsAreExact),
        ("Endpoint routing cache restores a bounded snapshot across service restart", SnapshotSurvivesRestart),
        ("Malformed endpoint snapshots cannot replace a currently admitted mapping", InvalidSnapshotsPreserveMapping),
        ("Selected numeric endpoint observations preserve signed literal and port scope", SelectedEndpointScopeIsExact),
        ("Endpoint routing cache rejects invalid keys, leases and oversized DNS answers", CacheAdmissionFailsClosed),
        ("UAPI recovery observes only the configured peer's numeric endpoint and freshness", PeerObservationIsSelectedAndNumeric),
        ("Unsupported optional UAPI endpoint metadata preserves genuine peer statistics", OptionalEndpointMetadataDoesNotRejectHealth),
        ("DNS resolution deadline bounds providers that ignore cancellation", DnsDeadlineBoundsIgnoredCancellation),
        ("DNS resolution preserves caller cancellation without classifying it as timeout", DnsCallerCancellationIsPreserved),
        ("DNS resolution keeps successful answers and resolver failures distinguishable", DnsResultsAndFailuresArePreserved),
    ];

    private static VpnEndpointAddressCache AdmittedCache()
    {
        var cache = new VpnEndpointAddressCache();
        Require(cache.RememberResolved(Endpoint, Peer, [IPAddress.Parse("192.0.2.1")], Now.AddMinutes(10), Now),
            "A valid admitted endpoint was rejected.");
        return cache;
    }

    private static void AdmissionBindingsAreExact()
    {
        var cache = AdmittedCache();
        Require(cache.Get(Endpoint, Peer, Now).Single().Equals(IPAddress.Parse("192.0.2.1")),
            "The admitted endpoint did not recover its numeric address.");
        Require(cache.Get(" VPN.EXAMPLE.TEST:443 ", Peer, Now).Count == 1,
            "Canonical hostname comparison changed the admitted peer scope.");
        foreach (var other in new[] { "other.example.test:443", "vpn.example.test:444", "192.0.2.1:443" })
        {
            Require(cache.Get(other, Peer, Now).Count == 0, "Cache crossed a signed endpoint or port boundary.");
        }
        Require(cache.Get(Endpoint, OtherPeer, Now).Count == 0 && cache.Get(Endpoint, null, Now).Count == 0,
            "Cache crossed a server identity boundary.");
        Require(cache.Get(Endpoint, Peer, Now.AddMinutes(10).AddTicks(-1)).Count == 1 &&
            cache.Get(Endpoint, Peer, Now.AddMinutes(10)).Count == 0,
            "Cache remained reusable at or after the signed lease expiry.");
    }

    private static void SnapshotSurvivesRestart()
    {
        var first = AdmittedCache();
        var serialized = JsonSerializer.Serialize(first.Snapshot);
        var restored = JsonSerializer.Deserialize<VpnEndpointAddressSnapshot>(serialized);
        var restarted = new VpnEndpointAddressCache();
        Require(restarted.Restore(restored, Now.AddMinutes(1)), "A valid persisted routing snapshot was not restored.");
        Require(restarted.Get(Endpoint, Peer, Now.AddMinutes(1)).SequenceEqual(first.Get(Endpoint, Peer, Now)),
            "Restart lost or changed the admitted numeric address.");
        Require(!new VpnEndpointAddressCache().Restore(restored, Now.AddMinutes(10)),
            "Restart revived a routing snapshot after its original signed expiry.");
    }

    private static void InvalidSnapshotsPreserveMapping()
    {
        var cache = AdmittedCache();
        var original = cache.Snapshot!;
        var invalid = new VpnEndpointAddressSnapshot?[]
        {
            null,
            original with { Endpoint = "" },
            original with { Endpoint = "vpn.example.test:0" },
            original with { ServerPublicKey = "invalid" },
            original with { ValidUntil = Now },
            original with { ValidUntil = Now.AddHours(24).AddTicks(1) },
            original with { Addresses = [] },
            original with { Addresses = ["not-an-address"] },
            original with { Addresses = null! },
            original with { Addresses = Enumerable.Range(1, 17).Select(index => $"192.0.2.{index}").ToArray() },
            original with { Endpoint = "192.0.2.1:443", Addresses = ["192.0.2.2"] },
        };
        foreach (var snapshot in invalid)
        {
            Require(!cache.Restore(snapshot, Now), "Malformed persisted routing metadata was accepted.");
            Require(cache.Snapshot == original && cache.Get(Endpoint, Peer, Now).Count == 1,
                "A failed cache restore erased the current admitted mapping.");
        }
    }

    private static void SelectedEndpointScopeIsExact()
    {
        var cache = AdmittedCache();
        Require(cache.ObserveSelectedPeer(Endpoint, Peer, "192.0.2.2:443", Now.AddMinutes(5), Now),
            "An authenticated selected peer could not seed its exact signed hostname.");
        Require(cache.Get(Endpoint, Peer, Now).Single().ToString() == "192.0.2.2" &&
            cache.Get(Endpoint, Peer, Now.AddMinutes(5)).Count == 0,
            "Observed peer address changed the signed port or extended its lease.");
        var original = cache.Snapshot;
        foreach (var numeric in new[] { "192.0.2.3:444", "vpn.example.test:443", "invalid", "[2001:db8::1]:0" })
        {
            Require(!cache.ObserveSelectedPeer(Endpoint, Peer, numeric, Now.AddMinutes(5), Now),
                "Unqualified selected peer metadata seeded routing recovery.");
            Require(cache.Snapshot == original, "Rejected selected peer metadata replaced the current mapping.");
        }
        Require(!cache.ObserveSelectedPeer("192.0.2.1:443", Peer, "192.0.2.2:443", Now.AddMinutes(5), Now),
            "A literal signed endpoint admitted a different authenticated peer address.");
        Require(cache.ObserveSelectedPeer("[2001:db8::1]:443", Peer, "[2001:db8::1]:443", Now.AddMinutes(5), Now) &&
            cache.Get("[2001:db8::1]:443", Peer, Now).Single().Equals(IPAddress.Parse("2001:db8::1")),
            "A qualified exact IPv6 endpoint was rejected.");
    }

    private static void CacheAdmissionFailsClosed()
    {
        var cache = AdmittedCache();
        var original = cache.Snapshot;
        foreach (var key in new[] { "", "invalid", Convert.ToBase64String(new byte[31]), Convert.ToBase64String(new byte[33]) })
        {
            Require(!cache.RememberResolved(Endpoint, key, [IPAddress.Loopback], Now.AddMinutes(5), Now),
                "An invalid configured server key admitted a DNS answer.");
        }
        foreach (var expiry in new DateTimeOffset?[] { null, Now, Now.AddSeconds(-1), Now.AddHours(24).AddTicks(1) })
        {
            Require(!cache.RememberResolved(Endpoint, Peer, [IPAddress.Loopback], expiry, Now),
                "A missing, expired or unbounded lease admitted a DNS answer.");
        }
        Require(!cache.RememberResolved(Endpoint, Peer, [], Now.AddMinutes(5), Now) &&
            !cache.RememberResolved(Endpoint, Peer,
                Enumerable.Range(1, 17).Select(index => IPAddress.Parse($"192.0.2.{index}")), Now.AddMinutes(5), Now),
            "An empty or oversized DNS answer entered the bounded cache.");
        Require(cache.Snapshot == original, "Failed DNS admission changed the current routing mapping.");
    }

    private static VpnPeerStatistics SelectedPeer(string? endpoint, long handshake)
    {
        var lines = new List<string>
        {
            "private_key=must-not-be-retained",
            "public_key=" + Convert.ToHexString(Convert.FromBase64String(OtherPeer)),
            "endpoint=192.0.2.99:443", "last_handshake_time_sec=" + Now.ToUnixTimeSeconds(),
            "public_key=" + Convert.ToHexString(Convert.FromBase64String(Peer)),
            "last_handshake_time_sec=" + handshake, "rx_bytes=42", "tx_bytes=84",
        };
        if (endpoint is not null) { lines.Add("endpoint=" + endpoint); }
        lines.Add("errno=0");
        return VpnPeerStatistics.Parse(lines, Peer);
    }

    private static void PeerObservationIsSelectedAndNumeric()
    {
        var peer = SelectedPeer("[2001:db8::1]:443", Now.AddSeconds(-1).ToUnixTimeSeconds());
        Require(peer.Endpoint == "[2001:db8::1]:443" && peer.RxBytes == 42 && peer.TxBytes == 84 &&
            peer.HasFreshHandshake(Now, TimeSpan.FromSeconds(180)),
            "Recovery used another peer's endpoint, bytes or handshake.");
        var cache = new VpnEndpointAddressCache();
        Require(cache.ObserveSelectedPeer(Endpoint, Peer, peer.Endpoint, Now.AddMinutes(5), Now) &&
            cache.Get(Endpoint, Peer, Now).Single().ToString() == "2001:db8::1",
            "Selected authenticated numeric metadata could not bootstrap hostname recovery.");
        var stale = SelectedPeer("192.0.2.1:443", Now.AddSeconds(-181).ToUnixTimeSeconds());
        Require(!stale.HasFreshHandshake(Now, TimeSpan.FromSeconds(180)),
            "Another peer's fresh handshake authorized a stale configured peer observation.");
    }

    private static void OptionalEndpointMetadataDoesNotRejectHealth()
    {
        foreach (var endpoint in new string?[] { null, "invalid", "vpn.example.test:443", "192.0.2.1:0" })
        {
            var peer = SelectedPeer(endpoint, Now.ToUnixTimeSeconds());
            Require(peer.Endpoint is null && peer.RxBytes == 42 && peer.HasFreshHandshake(Now, TimeSpan.FromSeconds(180)),
                "Unsupported optional endpoint metadata rejected otherwise valid peer health.");
        }
    }

    private static void DnsDeadlineBoundsIgnoredCancellation() => DnsDeadlineBoundsIgnoredCancellationAsync().GetAwaiter().GetResult();

    private static async Task DnsDeadlineBoundsIgnoredCancellationAsync()
    {
        var provider = new TaskCompletionSource<IPAddress[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            try
            {
                await BoundedDnsResolver.ResolveAsync("vpn.example.test", (_, _) => provider.Task,
                    TimeSpan.FromMilliseconds(50), CancellationToken.None).WaitAsync(deadline.Token).ConfigureAwait(false);
            }
            catch (VpnTunnelException error) when (error.Code == "endpoint_resolution_timeout") { return; }
            throw new InvalidOperationException("A DNS provider ignoring cancellation exceeded the bounded resolver deadline.");
        }
        finally { provider.TrySetResult([]); }
    }

    private static void DnsCallerCancellationIsPreserved() => DnsCallerCancellationIsPreservedAsync().GetAwaiter().GetResult();

    private static async Task DnsCallerCancellationIsPreservedAsync()
    {
        var provider = new TaskCompletionSource<IPAddress[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var caller = new CancellationTokenSource();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var resolution = BoundedDnsResolver.ResolveAsync("vpn.example.test", (_, _) =>
        {
            entered.SetResult();
            return provider.Task;
        }, TimeSpan.FromSeconds(30), caller.Token);
        try
        {
            await entered.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            caller.Cancel();
            try { await resolution.WaitAsync(deadline.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (caller.IsCancellationRequested && !deadline.IsCancellationRequested) { return; }
            throw new InvalidOperationException("Caller DNS cancellation was lost or became a resolution timeout.");
        }
        finally { provider.TrySetResult([]); }
    }

    private static void DnsResultsAndFailuresArePreserved() => DnsResultsAndFailuresArePreservedAsync().GetAwaiter().GetResult();

    private static async Task DnsResultsAndFailuresArePreservedAsync()
    {
        var addresses = new[] { IPAddress.Parse("192.0.2.1"), IPAddress.Parse("2001:db8::1") };
        var resolved = await BoundedDnsResolver.ResolveAsync("vpn.example.test", (host, _) =>
        {
            Require(host == "vpn.example.test", "The bounded resolver changed its admitted hostname.");
            return Task.FromResult(addresses);
        }, TimeSpan.FromSeconds(1), CancellationToken.None).ConfigureAwait(false);
        Require(resolved.SequenceEqual(addresses), "The bounded resolver changed a successful DNS answer.");
        try
        {
            await BoundedDnsResolver.ResolveAsync("vpn.example.test", (_, _) =>
                Task.FromException<IPAddress[]>(new SocketException((int)SocketError.HostNotFound)),
                TimeSpan.FromSeconds(1), CancellationToken.None).ConfigureAwait(false);
        }
        catch (SocketException error) when (error.SocketErrorCode == SocketError.HostNotFound) { return; }
        throw new InvalidOperationException("A resolver failure was hidden or misclassified as deadline expiry.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}

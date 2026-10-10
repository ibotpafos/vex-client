using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Service;
using Vex.Windows.Service.Runtime;

internal static class NetworkSafetyControllerRecoveryTests
{
    private const string Endpoint = "vpn.example.test:443";
    private const string ApiHost = "api.example.test";
    private const string EndpointAddress = "203.0.113.7";
    private const string ApiAddress = "198.51.100.8";
    private const string NextHop = "192.0.2.1";
    private static readonly string Peer = Convert.ToBase64String(Enumerable.Repeat((byte)7, 32).ToArray());
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(3);

    public static readonly (string Name, Action Run)[] All =
    [
        ("Actual network controller restores API and endpoint bypass before DNS after service restart", () => ColdPrimingRestoresBothAddressClassesAsync().GetAwaiter().GetResult()),
        ("Actual network controller classifies a shared DNS host as endpoint and control plane", () => SharedHostKeepsBothAddressClassesAsync().GetAwaiter().GetResult()),
        ("Actual network controller journals pending creation before a cancelled install and uses independent cleanup", () => CancelledInstallUsesPendingOwnershipAsync().GetAwaiter().GetResult()),
        ("Actual network controller cleans confirmed creation after cancellation without dropping its receipt", () => CancelledConfirmedCreationIsCleanedAsync().GetAwaiter().GetResult()),
        ("Actual network controller promotes a pending receipt without removing the live owned route", () => PendingReceiptPromotesWithoutDeletionAsync().GetAwaiter().GetResult()),
        ("Actual network controller retains malformed route journals and refuses mutation", () => MalformedJournalsRemainUnverifiedAsync().GetAwaiter().GetResult()),
        ("Actual network controller preserves ambiguous legacy route ownership after cleanup refusal", () => LegacyCleanupRefusalPreservesJournalAsync().GetAwaiter().GetResult()),
        ("Actual network controller retains journal and creation receipt after provider cleanup failure", () => CleanupFailureRetainsOwnershipForRetryAsync().GetAwaiter().GetResult()),
    ];

    private static async Task ColdPrimingRestoresBothAddressClassesAsync()
    {
        using var fixture = new Fixture([ApiHost]);
        var expiry = DateTimeOffset.UtcNow.AddMinutes(10);
        fixture.Write("endpoint-address-cache.json", new VpnEndpointAddressSnapshot(Endpoint, Peer, expiry, [EndpointAddress]));
        fixture.Write("control-plane-address-cache.json", new VpnControlPlaneAddressSnapshot(1, [ApiHost], Endpoint, Peer,
            expiry, [new(ApiHost, [ApiAddress])]));
        fixture.SeedFirewall();
        var controller = fixture.Create();

        await controller.EnsureKnownEndpointBypassAsync(Endpoint, Peer, default, expiry).WaitAsync(Deadline);
        Require(fixture.DnsCalls.Count == 0, "Cold numeric priming consulted the unavailable DNS resolver.");
        Require(fixture.FindAddresses.Order().SequenceEqual(new[] { EndpointAddress, ApiAddress }.Order()),
            "Cold restart primed the VPN endpoint but lost its admitted API bypass route.");
        Require(fixture.Calls.All(call => !IsInstall(call.Script) && !IsRemove(call.Script)),
            "Priming existing foreign routes attempted installation or claimed cleanup ownership.");
        fixture.RequireFirewallAddresses([EndpointAddress], [ApiAddress]);

        await controller.ApplyControlPlaneBypassAsync(Endpoint, default, Peer, expiry).WaitAsync(Deadline);
        Require(fixture.DnsCalls.Order().SequenceEqual(new[] { "vpn.example.test", ApiHost }.Order()),
            "Offline repair did not attempt each distinct configured DNS name exactly once.");
        Require(fixture.FindAddresses.Count(address => address == EndpointAddress) == 3 &&
            fixture.FindAddresses.Count(address => address == ApiAddress) == 3,
            "Offline repair discarded previously admitted numeric endpoint or API routes.");
        fixture.RequireFirewallAddresses([EndpointAddress], [ApiAddress]);
        var persisted = JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(File.ReadAllText(fixture.PathFor("control-plane-address-cache.json")));
        Require(persisted?.ValidUntil == expiry && persisted.Entries.Single().Addresses.SequenceEqual([ApiAddress]),
            "Failed DNS resolution erased or renewed the persisted control-plane lease.");
    }

    private static async Task SharedHostKeepsBothAddressClassesAsync()
    {
        using var fixture = new Fixture([ApiHost]);
        fixture.SeedFirewall();
        fixture.Resolve = (_, _) => Task.FromResult(new[] { IPAddress.Parse(ApiAddress) });
        var endpoint = ApiHost + ":443";
        var expiry = DateTimeOffset.UtcNow.AddMinutes(10);
        var controller = fixture.Create();

        await controller.ApplyControlPlaneBypassAsync(endpoint, default, Peer, expiry).WaitAsync(Deadline);
        Require(fixture.DnsCalls.SequenceEqual([ApiHost]) && fixture.FindAddresses.SequenceEqual([ApiAddress]),
            "A shared endpoint/control hostname was resolved or routed more than once.");
        fixture.RequireFirewallAddresses([ApiAddress], [ApiAddress]);
        var control = JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(File.ReadAllText(fixture.PathFor("control-plane-address-cache.json")));
        var peer = JsonSerializer.Deserialize<VpnEndpointAddressSnapshot>(File.ReadAllText(fixture.PathFor("endpoint-address-cache.json")));
        Require(control?.Entries.Single().Host == ApiHost && control.Entries.Single().Addresses.SequenceEqual([ApiAddress]) &&
            peer?.Endpoint == endpoint && peer.Addresses.SequenceEqual([ApiAddress]),
            "Shared-host resolution failed to persist each independent, exact-scope address classification.");
    }

    private static async Task CancelledInstallUsesPendingOwnershipAsync()
    {
        using var fixture = new Fixture([]);
        using var cancellation = new CancellationTokenSource();
        var installs = 0;
        var cleanups = 0;
        fixture.Run = (script, args, token) =>
        {
            if (IsFind(script)) return Task.FromResult(RouteResult(args[0], created: true));
            if (IsInstall(script))
            {
                installs++;
                using var journal = JsonDocument.Parse(File.ReadAllText(fixture.RouteJournal));
                var entry = journal.RootElement.GetProperty("Entries").EnumerateArray().Single();
                Require(journal.RootElement.GetProperty("Version").GetInt32() == 2 && !entry.GetProperty("Confirmed").GetBoolean() &&
                    entry.GetProperty("CreationId").GetString() == args[5] && entry.GetProperty("RouteMetric").GetInt32() == int.Parse(args[4]),
                    "Installation began without a durable pending creation identity.");
                Require(!File.Exists(args[6]), "A creation receipt was fabricated before the installation completed.");
                cancellation.Cancel();
                return Task.FromCanceled<string>(token);
            }
            if (IsRemove(script))
            {
                cleanups++;
                Require(!token.IsCancellationRequested && args[5].Length == 32 && !File.Exists(args[6]),
                    "Cancelled installation cleanup reused caller cancellation or lost its unconfirmed ownership identity.");
                return Task.FromResult("");
            }
            throw new InvalidOperationException("Unexpected command after cancelled installation.");
        };
        var controller = fixture.Create();
        await RequireCancellationAsync(() => controller.EnsureKnownEndpointBypassAsync(EndpointAddress + ":443", Peer,
            cancellation.Token, DateTimeOffset.UtcNow.AddMinutes(10)));
        Require(installs == 1 && cleanups == 1 && !File.Exists(fixture.RouteJournal) && controller.CleanupVerified(),
            "Safely completed cancellation rollback left a pending journal or failed to release controller ownership.");
    }

    private static async Task CancelledConfirmedCreationIsCleanedAsync()
    {
        using var fixture = new Fixture([]);
        using var cancellation = new CancellationTokenSource();
        var cleanups = 0;
        fixture.Run = (script, args, token) =>
        {
            if (IsFind(script)) return Task.FromResult(RouteResult(args[0], created: true));
            if (IsInstall(script))
            {
                fixture.WriteReceipt(args[5], args[0], int.Parse(args[1]), args[2], int.Parse(args[4]));
                return Task.FromResult("created");
            }
            if (IsVerifyRoute(script))
            {
                using var journal = JsonDocument.Parse(File.ReadAllText(fixture.RouteJournal));
                Require(journal.RootElement.GetProperty("Entries").EnumerateArray().Single().GetProperty("Confirmed").GetBoolean(),
                    "A completed creation receipt was not promoted before effective-route verification.");
                cancellation.Cancel();
                return Task.FromCanceled<string>(token);
            }
            if (IsRemove(script))
            {
                cleanups++;
                Require(!token.IsCancellationRequested && File.Exists(args[6]),
                    "Late cancellation discarded the creation receipt before independent cleanup.");
                File.Delete(args[6]);
                return Task.FromResult("");
            }
            throw new InvalidOperationException("Unexpected confirmed-creation command.");
        };
        var controller = fixture.Create();
        await RequireCancellationAsync(() => controller.EnsureKnownEndpointBypassAsync(EndpointAddress + ":443", Peer,
            cancellation.Token, DateTimeOffset.UtcNow.AddMinutes(10)));
        Require(cleanups == 1 && controller.CleanupVerified() && !Directory.EnumerateFiles(fixture.ReceiptsDirectory).Any(),
            "Confirmed-route cancellation left installed-route ownership evidence after verified rollback.");
    }

    private static async Task PendingReceiptPromotesWithoutDeletionAsync()
    {
        using var fixture = new Fixture([]);
        var creationId = Guid.NewGuid().ToString("N");
        fixture.SeedRoute(creationId, confirmed: false);
        var receipt = fixture.WriteReceipt(creationId, EndpointAddress, 10, NextHop, 2468);
        var receiptBytes = File.ReadAllBytes(receipt);
        fixture.Run = (script, args, _) =>
        {
            if (IsFind(script)) return Task.FromResult(RouteResult(args[0], metric: 2468));
            if (IsVerifyRoute(script)) return Task.FromResult("ok");
            throw new InvalidOperationException("Pending-to-confirmed promotion attempted installation or route deletion.");
        };
        var controller = fixture.Create();
        await controller.EnsureKnownEndpointBypassAsync(EndpointAddress + ":443", Peer, default,
            DateTimeOffset.UtcNow.AddMinutes(10)).WaitAsync(Deadline);
        using var journal = JsonDocument.Parse(File.ReadAllText(fixture.RouteJournal));
        var entry = journal.RootElement.GetProperty("Entries").EnumerateArray().Single();
        Require(entry.GetProperty("Confirmed").GetBoolean() && entry.GetProperty("CreationId").GetString() == creationId &&
            File.ReadAllBytes(receipt).SequenceEqual(receiptBytes) && !controller.CleanupVerified(),
            "Pending receipt recovery removed the live route or changed its stable ownership identity.");
        Require(fixture.Calls.All(call => !IsRemove(call.Script) && !IsInstall(call.Script)),
            "Confirmation status alone made the retained live route appear stale.");
    }

    private static async Task MalformedJournalsRemainUnverifiedAsync()
    {
        foreach (var invalid in new[] { "{", "{\"Version\":1,\"Entries\":[]}", "{\"Version\":2,\"Entries\":[null]}" })
        {
            using var fixture = new Fixture([]);
            File.WriteAllText(fixture.RouteJournal, invalid);
            var controller = fixture.Create();
            await RequireTunnelFailureAsync(() => controller.RollbackAsync(default), "route_ownership_journal_invalid");
            await RequireTunnelFailureAsync(() => controller.EnsureKnownEndpointBypassAsync(EndpointAddress + ":443", Peer,
                default, DateTimeOffset.UtcNow.AddMinutes(10)), "route_ownership_journal_invalid");
            Require(File.ReadAllText(fixture.RouteJournal) == invalid && fixture.Calls.Count == 0 &&
                fixture.DnsCalls.Count == 0 && !controller.CleanupVerified(),
                "Malformed ownership state was erased, treated as verified, or allowed a network mutation.");
        }
    }

    private static async Task LegacyCleanupRefusalPreservesJournalAsync()
    {
        using var fixture = new Fixture([]);
        fixture.Write("bypass-routes.json", new[] { new { Address = EndpointAddress, InterfaceIndex = 10, NextHop } });
        var original = File.ReadAllText(fixture.RouteJournal);
        fixture.Run = (script, args, _) =>
        {
            Require(IsRemove(script) && args[4] == "0" && args[5] == "" && args[6] == "",
                "Legacy ownership was converted into a fabricated creation fingerprint.");
            return Task.FromException<string>(new VpnTunnelException("route_legacy_ownership_unverified"));
        };
        var controller = fixture.Create();
        await RequireTunnelFailureAsync(() => controller.RollbackAsync(default), "route_legacy_ownership_unverified");
        Require(File.ReadAllText(fixture.RouteJournal) == original && !controller.CleanupVerified(),
            "Ambiguous legacy cleanup failure erased its journal or claimed successful route cleanup.");
    }

    private static async Task CleanupFailureRetainsOwnershipForRetryAsync()
    {
        using var fixture = new Fixture([]);
        var creationId = Guid.NewGuid().ToString("N");
        fixture.SeedRoute(creationId, confirmed: true);
        var receipt = fixture.WriteReceipt(creationId, EndpointAddress, 10, NextHop, 2468);
        var originalJournal = File.ReadAllBytes(fixture.RouteJournal);
        var originalReceipt = File.ReadAllBytes(receipt);
        var fail = true;
        fixture.Run = (script, args, _) =>
        {
            Require(IsRemove(script) && args[5] == creationId && args[6] == receipt && File.Exists(receipt),
                "Provider cleanup lost the exact persisted creation identity or receipt.");
            if (fail) return Task.FromException<string>(new IOException("The route provider could not read current ownership."));
            File.Delete(receipt);
            return Task.FromResult("");
        };
        var controller = fixture.Create();
        try
        {
            await controller.RollbackAsync(default).WaitAsync(Deadline);
            throw new InvalidOperationException("Provider read failure was reported as successful cleanup.");
        }
        catch (IOException) { }
        Require(File.ReadAllBytes(fixture.RouteJournal).SequenceEqual(originalJournal) &&
            File.ReadAllBytes(receipt).SequenceEqual(originalReceipt) && !controller.CleanupVerified(),
            "Failed provider cleanup discarded the durable journal or receipt needed for recovery.");
        fail = false;
        await controller.RollbackAsync(default).WaitAsync(Deadline);
        Require(fixture.Calls.Count == 2 && !File.Exists(receipt) && controller.CleanupVerified(),
            "A provider failure kept the operation gate locked or prevented verified cleanup retry.");
    }

    private static async Task RequireCancellationAsync(Func<Task> operation)
    {
        try { await operation().WaitAsync(Deadline); }
        catch (OperationCanceledException) { return; }
        throw new InvalidOperationException("Caller cancellation was not preserved after route cleanup.");
    }

    private static async Task RequireTunnelFailureAsync(Func<Task> operation, string code)
    {
        try { await operation().WaitAsync(Deadline); }
        catch (VpnTunnelException error) when (error.Code == code) { return; }
        throw new InvalidOperationException("Expected route safety failure: " + code);
    }

    private static bool IsFind(string script) => script.Contains("# Never use Find-NetRoute", StringComparison.Ordinal);
    private static bool IsInstall(string script) => script.Contains("# Receipt proves a completed creation", StringComparison.Ordinal);
    private static bool IsRemove(string script) => script.Contains("# Old tuple-only records", StringComparison.Ordinal);
    private static bool IsVerifyRoute(string script) => script.Contains("# Verify the effective route after owned", StringComparison.Ordinal);
    private static string RouteResult(string address, bool created = false, int metric = 10) => JsonSerializer.Serialize(new
    {
        Address = address, InterfaceIndex = 10, NextHop, Created = created, RouteMetric = metric, Protocol = "NetMgmt",
    });
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), "vex-network-controller-" + Guid.NewGuid().ToString("N"));
        private readonly IReadOnlyList<string> _hosts;
        public readonly List<(string Script, string[] Arguments)> Calls = [];
        public readonly List<string> DnsCalls = [];
        public Func<string, IReadOnlyList<string>, CancellationToken, Task<string>>? Run;
        public Func<string, CancellationToken, Task<IPAddress[]>> Resolve = (_, _) =>
            Task.FromException<IPAddress[]>(new SocketException((int)SocketError.HostNotFound));
        public string RouteJournal => PathFor("bypass-routes.json");
        public string ReceiptsDirectory => PathFor("bypass-route-confirmations");
        public IEnumerable<string> FindAddresses => Calls.Where(call => IsFind(call.Script)).Select(call => call.Arguments[0]);

        public Fixture(IReadOnlyList<string> hosts)
        {
            _hosts = hosts;
            Directory.CreateDirectory(_directory);
        }

        public string PathFor(string filename) => Path.Combine(_directory, filename);
        public void Write<T>(string filename, T value) => File.WriteAllText(PathFor(filename), JsonSerializer.Serialize(value));

        public NetworkSafetyController Create() => new(new WindowsServiceOptions(_directory, _directory,
            PathFor("authorization"), PathFor("client-certificate"), PathFor("owner"), PathFor("amnezia"),
            PathFor("wintun"), PathFor("keyring"), PathFor("keyring-pin")) { ControlPlaneBypassHosts = _hosts },
            (script, args, token) =>
            {
                Calls.Add((script, args.ToArray()));
                if (Run is not null) return Run(script, args, token);
                if (IsFind(script)) return Task.FromResult(RouteResult(args[0]));
                if (IsVerifyRoute(script) || script.Contains("firewall_external_allow_active", StringComparison.Ordinal)) return Task.FromResult("ok");
                if (script.Contains("# Narrow an existing owned policy", StringComparison.Ordinal)) return Task.FromResult("");
                throw new InvalidOperationException("Unexpected network mutation in controller recovery test.");
            }, (host, token) =>
            {
                DnsCalls.Add(host);
                return Resolve(host, token);
            });

        public void SeedFirewall() => Write("firewall-rollback.json", new
        {
            Version = 3,
            Profiles = new[] { "Domain", "Private", "Public" }.Select(name => new { Name = name, Enabled = "True", DefaultOutboundAction = "Allow" }).ToArray(),
            DisabledOutboundAllowRuleNames = Array.Empty<string>(),
            OwnedRuleNames = Enumerable.Range(0, 6).Select(index => "VEX.AntiLeak.fixture." + index).ToArray(),
            AdapterName = "VEX", ProtectedAddresses = new[] { EndpointAddress }, EndpointAddresses = new[] { EndpointAddress },
            EndpointPort = 443, ControlPlaneAddresses = Array.Empty<string>(),
        });

        public void RequireFirewallAddresses(string[] endpoint, string[] control)
        {
            using var journal = JsonDocument.Parse(File.ReadAllText(PathFor("firewall-rollback.json")));
            Require(journal.RootElement.GetProperty("EndpointAddresses").EnumerateArray().Select(value => value.GetString()).Order()
                .SequenceEqual(endpoint.Order()) && journal.RootElement.GetProperty("ControlPlaneAddresses").EnumerateArray()
                .Select(value => value.GetString()).Order().SequenceEqual(control.Order()),
                "Firewall refresh lost the independent numeric endpoint/control-plane address bounds.");
        }

        public void SeedRoute(string creationId, bool confirmed) => Write("bypass-routes.json", new
        {
            Version = 2,
            Entries = new[] { new { Address = EndpointAddress, InterfaceIndex = 10, NextHop, RouteMetric = 2468,
                CreationId = creationId, Confirmed = confirmed, Legacy = false } },
        });

        public string WriteReceipt(string creationId, string address, int interfaceIndex, string nextHop, int metric)
        {
            Directory.CreateDirectory(ReceiptsDirectory);
            var filename = Path.Combine("bypass-route-confirmations", creationId + ".json");
            Write(filename, new { CreationId = creationId, Address = address, InterfaceIndex = interfaceIndex, NextHop = nextHop,
                RouteMetric = metric, Protocol = "NetMgmt" });
            return PathFor(filename);
        }

        public void Dispose() => Directory.Delete(_directory, recursive: true);
    }
}

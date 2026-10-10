using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Client.Security;
using System.Security.Cryptography;
using Vex.Windows.Core.Vpn;

internal static class AccountVpnIdentityTests
{
    public static void RunRegistrationEpochRegression() => RegistrationAcceptsSameKeyServerEpochAdvanceAsync().GetAwaiter().GetResult();

    public static void Run()
    {
        BFirstHistoricalPairCollisionIsRepairedAsync().GetAwaiter().GetResult();
        AccountSwitchPreservesIndependentRegistrationAsync().GetAwaiter().GetResult();
        ReopenedCoordinatorPreservesAccountsAsync().GetAwaiter().GetResult();
        UpgradedLegacyAccountSurvivesSwitchAsync().GetAwaiter().GetResult();
        DurableAccountsAndPendingKeysSurviveReopen();
        LegacyPairHasOnlyOneAdoptionOwner();
        StrictMapFailuresNeverReplaceExistingBytes();
        HistoricalOwnerBindingRepairAsync().GetAwaiter().GetResult();
        RegistrationErrorsNeverRepairAsync().GetAwaiter().GetResult();
        FailedLookupOrPersistenceNeverRegistersAsync().GetAwaiter().GetResult();
        SupersededLookupNeverCreatesIdentityAsync().GetAwaiter().GetResult();
        NativeRetirementPrecedesNextAccountAsync().GetAwaiter().GetResult();
        FailedNativeRetirementBlocksAccountAsync().GetAwaiter().GetResult();
        SupersededRefreshAndProfileNeverActivateAsync().GetAwaiter().GetResult();
        ValidAccountSwitchRetiresConnectedOwnerAsync().GetAwaiter().GetResult();
        LogoutWaitsForConfirmedRetirementAsync().GetAwaiter().GetResult();
        SupersededSelectionCannotRollbackOldAccountAsync().GetAwaiter().GetResult();
        RegistrationAcceptsSameKeyServerEpochAdvanceAsync().GetAwaiter().GetResult();
        LockedStoredAccountRequiresRetirementAsync().GetAwaiter().GetResult();
        PendingRotationReplaysBeforeRegistrationAfterReopenAsync().GetAwaiter().GetResult();
        RejectedSessionRetiresBeforeLosingOwnerAsync().GetAwaiter().GetResult();
        ScopedRegistrationRequiresIdentityProofAsync().GetAwaiter().GetResult();
    }

    private static async Task BFirstHistoricalPairCollisionIsRepairedAsync()
    {
        using var fixture = new Fixture();
        var legacy = WireGuardIdentity.Generate(4);
        fixture.Store.SetLegacyDeviceForTest(new("win-installation-1", "device-account-a", "fi-1", legacy));
        fixture.Server.Seed("account-a", LegacyDevice("account-a", legacy.PublicKey), bindingOwner: "account-a");
        fixture.Server.Seed("account-b", LegacyDevice("account-b", legacy.PublicKey));
        await fixture.SignInAsync("account-b");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success, "B-first historical own row must recover.");
        var a = fixture.Server.Device("account-a", "win-installation-1");
        var b = fixture.Server.Device("account-b", "win-installation-1");
        Check(b.PublicKey != legacy.PublicKey && a.PublicKey == legacy.PublicKey && a.PskEpoch == 4 &&
            fixture.Store.LoadDevice()!.Identity == legacy && fixture.Server.Rotations.Count == 1 &&
            fixture.Server.Rotations.Single().Owner == "account-b" && fixture.Server.DeviceCount == 2,
            "B-first exact409 repair must install fresh scoped B WG pair immediately while preserving unmigrated A/global pair and quota rows.");
    }

    private static async Task AccountSwitchPreservesIndependentRegistrationAsync()
    {
        using var fixture = new Fixture();
        await fixture.SignInAsync("account-a");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success, "Account A must connect.");
        var first = fixture.Store.State!;
        var firstRegistration = fixture.Server.Registrations.Single();
        await fixture.SignInAsync("account-b");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success,
            "Account B must register independently instead of replaying account A's installation and idempotency key.");
        var second = fixture.Store.State!;
        var secondRegistration = fixture.Server.Registrations.Last();
        Check(first.InstallationId == second.InstallationId && firstRegistration.Installation != secondRegistration.Installation &&
            firstRegistration.Idempotency != secondRegistration.Idempotency && first.Identity.PublicKey != second.Identity.PublicKey,
            "Auth installation stays global; VPN registration, idempotency and WireGuard pairs must belong to each account.");
        await fixture.SignInAsync("account-a");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success,
            "Returning to account A must recover its retained registration and key without another quota slot.");
        Check(fixture.Server.Registrations.Last().Installation == firstRegistration.Installation &&
            fixture.Store.State!.Identity == first.Identity && fixture.Server.DeviceCount == 2,
            "A to B to A must preserve both owners and exactly one device for each account.");
    }

    private static async Task ReopenedCoordinatorPreservesAccountsAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-coordinator-reopen-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "accounts.bin");
        try
        {
            NativeVpnAccountIdentity a;
            using (var first = new Fixture(FileStore(path)))
            {
                await first.SignInAsync("account-a");
                await first.Coordinator.ConnectAsync(CancellationToken.None);
                a = first.Store.AccountVpnIdentities.Load("account-a")!;
                await first.SignInAsync("account-b");
                await first.Coordinator.ConnectAsync(CancellationToken.None);
            }
            using var restarted = new Fixture(FileStore(path));
            restarted.Server.Seed("account-a", LegacyDevice("account-a", a.Identity.PublicKey, a.Identity.KeyEpoch, a.ExternalDeviceId));
            await restarted.SignInAsync("account-a");
            Check((await restarted.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
                restarted.Store.State!.Identity == a.Identity && restarted.Server.Registrations.Single().Installation == a.RegistrationId &&
                restarted.Store.AccountVpnIdentities.Load("account-b") is not null,
                "Reopened actual coordinator must return to A's durable pair and registration while retaining B.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static async Task UpgradedLegacyAccountSurvivesSwitchAsync()
    {
        using var fixture = new Fixture();
        var legacy = WireGuardIdentity.Generate(4);
        var owner = new VexAuthSession(new("account-a", "a@example.test", "active"), "access-account-a", DateTimeOffset.UtcNow.AddDays(1));
        fixture.Store.Save(new(owner, "win-installation-1", "device-account-a", "fi-1", legacy));
        fixture.Server.Seed("account-a", LegacyDevice("account-a", legacy.PublicKey), bindingOwner: "account-a");
        await fixture.SignInAsync("account-b");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Store.LoadDevice()!.Identity == legacy && fixture.Store.LoadDevice()!.UserId == "account-a",
            "Scoped B saves must preserve unmapped A's global legacy migration source.");
        await fixture.SignInAsync("account-a");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.Store.State!.Identity == legacy && fixture.Server.Rotations.Count == 0 && fixture.Server.DeviceCount == 2,
            "Upgraded A to B to A must adopt original A pair without a third device or unnecessary rotation.");
    }

    private static VpnDevice LegacyDevice(string owner, string publicKey, int epoch = 4,
        string external = "win-installation-1") => new("device-" + owner, "Windows", "active", publicKey,
            ProvisioningMode: "managed_native", ClientKeyOwnership: "client", ExternalDeviceId: external,
            Platform: "windows", UserId: owner, PskEpoch: epoch);

    private static void DurableAccountsAndPendingKeysSurviveReopen()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-account-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "accounts.bin");
        try
        {
            var store = FileStore(path);
            var a = store.GetOrAdd(new("a", "same-legacy", "same-legacy", WireGuardIdentity.Generate()));
            var b = store.GetOrAdd(new("b", "same-legacy", "same-legacy", WireGuardIdentity.Generate()));
            var pending = WireGuardIdentity.Generate(2);
            store.Replace(a, a with { PendingIdentity = pending });
            var reopened = FileStore(path);
            Check(reopened.Load("a")!.Identity == a.Identity && reopened.Load("a")!.PendingIdentity == pending &&
                reopened.Load("b") == b && a.Identity.PublicKey != b.Identity.PublicKey,
                "Actual atomic serialized map must retain account pairs and uncertain rotation across reopening.");
            var session = new VexAuthSession(new("a", "a@example.test", "active"), "token", DateTimeOffset.UtcNow.AddDays(1));
            var state = new NativeClientState(session, "global", "device-a", "fi-1", a.Identity,
                VpnRegistrationId: a.RegistrationId, VpnExternalDeviceId: a.ExternalDeviceId);
            Check(NativeVpnAccountIdentitySynchronization.Restore(reopened, state).PendingIdentity == pending,
                "Durable pending mapping must override stale session state after a torn two-file save.");
            var expected = reopened.Load("a")!;
            reopened.Replace(expected, expected with { Identity = pending, PendingIdentity = null });
            var restored = NativeVpnAccountIdentitySynchronization.Restore(reopened, state);
            Check(restored.Identity == pending && restored.PendingIdentity is null, "Acknowledged durable key cannot be rolled back.");
            ExpectFailure(() => NativeVpnAccountIdentitySynchronization.Save(reopened, state));
            Check(reopened.Load("a")!.Identity == pending, "Stale save must not overwrite newly acknowledged key.");
            var winners = Enumerable.Range(0, 8).AsParallel().Select(_ => FileStore(path)
                .GetOrAdd(new("concurrent", "win-concurrent", "win-concurrent", WireGuardIdentity.Generate()))).ToArray();
            Check(winners.All(value => value == winners[0]) && reopened.Load("b") == b,
                "Concurrent store instances must share one durable identity and preserve other accounts.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static void LegacyPairHasOnlyOneAdoptionOwner()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-legacy-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "accounts.bin");
        try
        {
            var legacy = WireGuardIdentity.Generate(4);
            var store = FileStore(path);
            var a = store.GetOrAdd(new("a", "same-legacy", "same-legacy", legacy), claimLegacyKey: true);
            var b = FileStore(path).GetOrAdd(new("b", "same-legacy", "same-legacy", legacy), claimLegacyKey: true);
            Check(a.Identity == legacy && b.Identity.PublicKey != legacy.PublicKey &&
                b.MigrationRotationPending && b.Identity.KeyEpoch == 5,
                "Only first owner may adopt the global legacy WG pair; another own row needs scoped next-epoch rotation.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static NativeVpnAccountIdentityFileStore FileStore(string path) => new(path,
        bytes => bytes.ToArray(), bytes => bytes.ToArray());

    private static void StrictMapFailuresNeverReplaceExistingBytes()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-corrupt-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "accounts.bin");
        try
        {
            Directory.CreateDirectory(directory);
            foreach (var corrupt in new[] { "invalid-json", "{}", "{\"Version\":1,\"Accounts\":{\"a\":null}}",
                "{\"Version\":1,\"Accounts\":{\"a\":{\"UserId\":\"a\"}}}" })
            {
                File.WriteAllText(path, corrupt);
                ExpectFailure(() => FileStore(path).GetOrAdd(new("a", "win-a", "win-a", WireGuardIdentity.Generate())));
                Check(File.ReadAllText(path) == corrupt, "Corrupt map must remain unchanged instead of speculative replacement.");
            }
            File.Delete(path);
            var unavailable = new NativeVpnAccountIdentityFileStore(path,
                _ => throw new IOException("write unavailable"), bytes => bytes.ToArray());
            ExpectFailure(() => unavailable.GetOrAdd(new("a", "win-a", "win-a", WireGuardIdentity.Generate())));
            Check(!File.Exists(path), "Failed atomic write must not expose a partial identity.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static async Task HistoricalOwnerBindingRepairAsync()
    {
        using var fixture = new Fixture();
        var legacy = WireGuardIdentity.Generate(4);
        var owner = new VexAuthSession(new("account-b", "b@example.test", "active"), "old-b", DateTimeOffset.UtcNow.AddDays(1));
        fixture.Store.Save(new(owner, "win-installation-1", "device-account-b", "fi-1", legacy));
        fixture.Server.Seed("account-b", LegacyDevice("account-b", legacy.PublicKey), bindingOwner: "account-a");
        await fixture.SignInAsync("account-b");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success, "Own historical row must recover exact rebind conflict.");
        var mapping = fixture.Store.AccountVpnIdentities.Load("account-b")!;
        Check(fixture.Server.Registrations.Count == 2 && mapping.RegistrationId != "win-installation-1" &&
            mapping.ExternalDeviceId == "win-installation-1" && mapping.Identity.PublicKey != legacy.PublicKey &&
            mapping.Identity.KeyEpoch == 5 && fixture.Store.LoadDevice()!.Identity == legacy && fixture.Server.DeviceCount == 1,
            "Exact conflict repair preserves external device quota row/global pair and commits a fresh scoped owner key.");
        Check(fixture.Server.Challenges.Count == 2 && fixture.Server.Challenges[0].Installation == "win-installation-1" &&
            fixture.Server.Challenges[1].Installation == mapping.RegistrationId &&
            fixture.Server.SignedRegistrations.All(item => item.Signer == fixture.IdentityProvider.Identity.PublicKey &&
                item.External == "win-installation-1"),
            "Repair must obtain a fresh signed challenge for scoped installation while keeping P256 signer/external ID.");
    }

    private static async Task RegistrationErrorsNeverRepairAsync()
    {
        foreach (var body in new object[] { new { code = "conflict" }, new { code = "conflict", message = "other" },
            new { code = "other", message = "device_rebind_required" } })
        {
            using var fixture = new Fixture();
            var legacy = WireGuardIdentity.Generate(4);
            fixture.Server.Seed("account-a", LegacyDevice("account-a", legacy.PublicKey));
            fixture.Server.RegistrationError = HttpStatusCode.Conflict;
            fixture.Server.ErrorBody = body;
            await fixture.SignInAsync("account-a");
            await ExpectFailureAsync(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Server.Registrations.Count == 1 &&
                fixture.Store.AccountVpnIdentities.Load("account-a")!.RegistrationId == "win-installation-1",
                "Generic or wrong-shaped409 must never trigger installation repair.");
        }
    }

    private static async Task FailedLookupOrPersistenceNeverRegistersAsync()
    {
        using (var fixture = new Fixture())
        {
            fixture.Proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = _ => throw new IOException("catalog unavailable");
            await fixture.SignInAsync("account-a");
            await ExpectFailureAsync(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Store.AccountVpnIdentities.Load("account-a") is null && fixture.Server.Registrations.Count == 0,
                "Unavailable first owner catalog must not allocate or register an identity.");
        }
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-write-fail-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new NativeVpnAccountIdentityFileStore(Path.Combine(directory, "accounts.bin"),
                _ => throw new IOException("cannot persist identity"), bytes => bytes.ToArray());
            using var fixture = new Fixture(store);
            await fixture.SignInAsync("account-a");
            await ExpectFailureAsync(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Server.Registrations.Count == 0, "Persistence failure must precede and prevent registration POST.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static async Task SupersededLookupNeverCreatesIdentityAsync()
    {
        using var fixture = new Fixture();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<IReadOnlyList<VpnDevice>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = _ => { entered.SetResult(); return release.Task; };
        await fixture.SignInAsync("account-a");
        var connecting = fixture.Coordinator.ConnectAsync(CancellationToken.None);
        await entered.Task;
        var switching = fixture.SignInAsync("account-b");
        release.SetResult([]);
        await ExpectFailureAsync(() => connecting);
        await switching;
        Check(fixture.Store.State!.Session.User.Id == "account-b" && fixture.Server.Registrations.Count == 0 &&
            fixture.Store.AccountVpnIdentities.Load("account-a") is null,
            "A pending catalog must not create or register after B account-switch intent arrives.");
    }

    private static async Task NativeRetirementPrecedesNextAccountAsync()
    {
        foreach (var uncertain in new[] { false, true })
        {
            var vpn = new ControlledVpnClient { ThrowAfterActivation = uncertain };
            using var fixture = new Fixture(vpn: vpn);
            await fixture.SignInAsync("account-a");
            var connecting = fixture.Coordinator.ConnectAsync(CancellationToken.None);
            await vpn.Entered.Task;
            var switching = fixture.SignInAsync("account-b");
            vpn.Release.SetResult();
            await vpn.StopEntered.Task;
            Check(!switching.IsCompleted && fixture.Store.State!.Session.User.Id == "account-a" &&
                fixture.Store.State.NativeRetirementRequired,
                "B must wait while A's late success or uncertain canceled activation is being retired.");
            await Task.Delay(40);
            Check(!switching.IsCompleted, "Cleanup must retain account gate until actual disconnect acknowledgement.");
            vpn.StopRelease.SetResult();
            await ExpectFailureAsync(() => connecting);
            await switching;
            Check(!vpn.Active && vpn.Stops == 1 && fixture.Store.State!.Session.User.Id == "account-b",
                "Confirmed native retirement must precede B admission for both uncertain and late-success responses.");
        }
    }

    private static async Task FailedNativeRetirementBlocksAccountAsync()
    {
        var vpn = new ControlledVpnClient { ThrowAfterActivation = true, FailStop = true };
        using var fixture = new Fixture(vpn: vpn);
        await fixture.SignInAsync("account-a");
        var connecting = fixture.Coordinator.ConnectAsync(CancellationToken.None);
        await vpn.Entered.Task;
        var switching = fixture.SignInAsync("account-b");
        vpn.Release.SetResult();
        vpn.StopRelease.SetResult();
        await ExpectFailureAsync(() => connecting);
        await ExpectFailureAsync(() => switching);
        Check(fixture.Store.State!.Session.User.Id == "account-a" && fixture.Store.State.NativeRetirementRequired && vpn.Active,
            "Failed retirement must preserve blocked recoverable A state and never silently admit B.");
        vpn.FailStop = false;
        await fixture.SignInAsync("account-b");
        Check(!vpn.Active && fixture.Store.State!.Session.User.Id == "account-b",
            "Retry must confirm retirement before admitting B.");
    }

    private static async Task SupersededRefreshAndProfileNeverActivateAsync()
    {
        foreach (var duringRefresh in new[] { true, false })
        {
            var vpn = new ControlledVpnClient();
            using var fixture = new Fixture(vpn: vpn);
            var session = new VexAuthSession(new("account-a", "a@example.test", "active"), "access-account-a",
                duringRefresh ? DateTimeOffset.UtcNow.AddSeconds(-1) : DateTimeOffset.UtcNow.AddDays(1));
            var key = WireGuardIdentity.Generate();
            fixture.Store.Save(new(session, "win-installation-1", "device-account-a", "fi-1", key));
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (duringRefresh)
                fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ => AwaitSession();
            else fixture.Proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = _ => AwaitRejectedProfile();
            var connecting = fixture.Coordinator.ConnectWithRecoveryAsync(null, "full", true, true, CancellationToken.None);
            await entered.Task;
            var switching = fixture.SignInAsync("account-b");
            release.SetResult();
            await ExpectFailureAsync(() => connecting);
            await switching;
            Check(!vpn.Entered.Task.IsCompleted && fixture.Server.Registrations.Count == 0 && fixture.Server.Rotations.Count == 0,
                "Queued B must fence A's native activation and mutations through refresh,401 retry and recovery.");
            async Task<VexAuthSession> AwaitSession() { entered.SetResult(); await release.Task; return session with { ExpiresAt = DateTimeOffset.UtcNow.AddDays(1) }; }
            async Task<ManagedVpnProfile> AwaitRejectedProfile() { entered.SetResult(); await release.Task; throw new VexApiException(HttpStatusCode.Unauthorized, "session_rejected"); }
        }
    }

    private static async Task ValidAccountSwitchRetiresConnectedOwnerAsync()
    {
        var vpn = new ControlledVpnClient();
        vpn.Release.SetResult();
        using var fixture = new Fixture(vpn: vpn);
        await fixture.SignInAsync("account-a");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        fixture.Proxy.Overrides[nameof(INativeClientApi.LoginAsync)] = _ =>
            Task.FromException<VexAuthSession>(new VexApiException(HttpStatusCode.Unauthorized, "invalid_credentials"));
        await ExpectFailureAsync(() => fixture.SignInAsync("account-b"));
        Check(vpn.Active && vpn.Stops == 0 && fixture.Store.State!.Session.User.Id == "account-a",
            "Invalid B credentials must preserve successful A connection.");
        fixture.Proxy.Overrides.Remove(nameof(INativeClientApi.LoginAsync));
        var switching = fixture.Coordinator.AcceptAuthenticatedSessionAsync(new(new("account-b", "b@example.test", "active"),
            "access-account-b", DateTimeOffset.UtcNow.AddDays(1)), CancellationToken.None);
        await vpn.StopEntered.Task;
        Check(!switching.IsCompleted && fixture.Store.State!.Session.User.Id == "account-a",
            "Valid B acceptance must wait for confirmed retirement of connected A before saving B.");
        vpn.StopRelease.SetResult();
        await switching;
        Check(!vpn.Active && fixture.Store.State!.Session.User.Id == "account-b" && fixture.Store.State.VpnProvisioningPending,
            "B stays signed in even without autoconnect while A tunnel is retired.");
    }

    private static async Task LogoutWaitsForConfirmedRetirementAsync()
    {
        var vpn = new ControlledVpnClient();
        vpn.Release.SetResult();
        using var fixture = new Fixture(vpn: vpn);
        await fixture.SignInAsync("account-a");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        using var canceled = new CancellationTokenSource();
        var logout = fixture.Coordinator.SignOutAsync(canceled.Token);
        await vpn.StopEntered.Task;
        canceled.Cancel();
        var switching = fixture.SignInAsync("account-b");
        Check(!logout.IsCompleted && !switching.IsCompleted && fixture.Store.State!.NativeRetirementRequired,
            "Canceled logout cannot clear durable retirement state or release an outstanding stop to B.");
        vpn.StopRelease.SetResult();
        await logout;
        await switching;
        Check(!vpn.Active && fixture.Store.State!.Session.User.Id == "account-b",
            "Logout acknowledgement must precede B login even after caller cancellation.");
    }

    private static async Task SupersededSelectionCannotRollbackOldAccountAsync()
    {
        var vpn = new ControlledVpnClient();
        vpn.Release.SetResult();
        using var fixture = new Fixture(vpn: vpn);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ => Task.FromResult<IReadOnlyList<VpnLocation>>([
            new("fi-1", "Helsinki", "available", 1, Awg3Nodes: 1), new("se-1", "Stockholm", "available", 1, Awg3Nodes: 1)]);
        await fixture.SignInAsync("account-a");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = _ => RejectLater();
        var selecting = fixture.Coordinator.SelectLocationAsync("se-1", true, CancellationToken.None);
        await entered.Task;
        var switching = fixture.SignInAsync("account-b");
        release.SetResult();
        await ExpectFailureAsync(() => selecting);
        await vpn.StopEntered.Task;
        vpn.StopRelease.SetResult();
        await switching;
        Check(vpn.Connects == 1 && !vpn.Active && fixture.Store.State!.Session.User.Id == "account-b",
            "Superseded selection/recovery cannot reactivate A's old signed grant in rollback.");
        async Task<ManagedVpnProfile> RejectLater() { entered.SetResult(); await release.Task; throw new VexApiException(HttpStatusCode.Unauthorized, "session_rejected"); }
    }

    private static async Task RegistrationAcceptsSameKeyServerEpochAdvanceAsync()
    {
        using var fixture = new Fixture();
        await fixture.SignInAsync("account-a");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        var previous = fixture.Store.State!;
        var oldHeader = fixture.Server.Registrations.Single().Idempotency;
        var device = fixture.Server.Device("account-a", previous.VpnExternalDeviceId!);
        fixture.Server.Seed("account-a", device with { PskEpoch = previous.Identity.KeyEpoch + 1 });
        await fixture.SignInAsync("account-a");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.Store.State!.Identity == previous.Identity with { KeyEpoch = previous.Identity.KeyEpoch + 1 } &&
            fixture.Server.Rotations.Count == 0 && fixture.Server.Registrations.Last().Idempotency != oldHeader,
            "PSK-only server epoch advance must synchronize live own DTO before creation-idempotency replay, preserving WG pair.");
    }

    private static async Task PendingRotationReplaysBeforeRegistrationAfterReopenAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-win-pending-reopen-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "accounts.bin");
        try
        {
            var previous = WireGuardIdentity.Generate(4);
            var pending = WireGuardIdentity.Generate(5);
            var stored = FileStore(path);
            stored.GetOrAdd(new("account-a", "win-scoped-a", "win-scoped-a", previous,
                DeviceId: "device-account-a", PendingIdentity: pending));
            using var fixture = new Fixture(FileStore(path));
            fixture.Server.Seed("account-a", LegacyDevice("account-a", pending.PublicKey, 6, "win-scoped-a"));
            await fixture.SignInAsync("account-b");
            await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            await fixture.SignInAsync("account-a");
            Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
                fixture.Store.State!.Identity == pending with { KeyEpoch = 6 } && fixture.Store.State.PendingIdentity is null &&
                FileStore(path).Load("account-a")!.Identity == pending with { KeyEpoch = 6 } && FileStore(path).Load("account-a")!.PendingIdentity is null &&
                fixture.Server.Rotations.Count == 0 &&
                fixture.Server.Registrations.Last().PublicKey == pending.PublicKey,
                "Lost response plus PSK advance must confirm the durable intended pair/live epoch before registration on reopened A to B to A flow.");
            var now = FileStore(path).Load("account-a")!;
            var next = WireGuardIdentity.Generate(7);
            FileStore(path).Replace(now, now with { PendingIdentity = next });
            fixture.Server.Seed("account-a", LegacyDevice("account-a", pending.PublicKey, 8, "win-scoped-a"));
            await fixture.SignInAsync("account-a");
            await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            Check(fixture.Store.State!.Identity == next with { KeyEpoch = 9 } && fixture.Server.Rotations.Single().Identity.PublicKey == next.PublicKey,
                "Still-unapplied pending pair must rebase to authoritative next epoch without generating another private key.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static async Task RejectedSessionRetiresBeforeLosingOwnerAsync()
    {
        var vpn = new ControlledVpnClient { FailStop = true };
        vpn.Release.SetResult();
        vpn.StopRelease.SetResult();
        using var fixture = new Fixture(vpn: vpn);
        await fixture.SignInAsync("account-a");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            Task.FromException<VexAuthSession>(new VexApiException(HttpStatusCode.Unauthorized, "session_rejected"));
        await ExpectFailureAsync(() => fixture.Coordinator.ForceRefreshSessionAsync(CancellationToken.None));
        // The general retry path receives an authoritative401 twice.
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetCurrentUserAsync)] = _ =>
            Task.FromException<VexUser>(new VexApiException(HttpStatusCode.Unauthorized, "session_rejected"));
        await ExpectFailureAsync(() => fixture.Coordinator.GetAccountSnapshotAsync(CancellationToken.None));
        Check(fixture.Store.State?.Session.User.Id == "account-a" && fixture.Store.State.NativeRetirementRequired && vpn.Active,
            "Unconfirmed retirement on rejected session must retain durable owner state instead of clearing A under a live tunnel.");
        vpn.FailStop = false;
        await fixture.SignInAsync("account-b");
        Check(!vpn.Active && fixture.Store.State!.Session.User.Id == "account-b",
            "B admission must recover the rejected A retirement barrier before replacing its owner state.");
    }

    private static async Task ScopedRegistrationRequiresIdentityProofAsync()
    {
        foreach (var unavailable in new[] { "provider", "challenge" })
        {
            var vpn = new ControlledVpnClient();
            using var fixture = new Fixture(vpn: vpn, signerAvailable: unavailable != "provider");
            var legacy = WireGuardIdentity.Generate(4);
            fixture.Store.SetLegacyDeviceForTest(new("win-installation-1", "device-account-a", "fi-1", legacy));
            fixture.Server.Seed("account-a", LegacyDevice("account-a", legacy.PublicKey));
            if (unavailable == "challenge") fixture.Server.ChallengeError = HttpStatusCode.NotFound;
            await fixture.SignInAsync("account-a");
            await ExpectFailureAsync(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Store.State!.VpnProvisioningPending && fixture.Store.AccountVpnIdentities.Load("account-a") is not null &&
                fixture.Server.Registrations.Count == 0 && !vpn.Entered.Task.IsCompleted,
                "Unavailable P256 signer/challenge must retain durable pending migration without unsigned registration/profile/native activation.");
        }
    }

    private static async Task LockedStoredAccountRequiresRetirementAsync()
    {
        var vpn = new ControlledVpnClient { FailStop = true };
        vpn.SeedActive();
        vpn.StopRelease.SetResult();
        using var fixture = new Fixture(vpn: vpn, accessStore: store => new HiddenSessionStore(store));
        var a = new VexAuthSession(new("account-a", "a@example.test", "active"), "access-account-a", DateTimeOffset.UtcNow.AddDays(1));
        fixture.Store.Save(new(a, "win-installation-1", "device-account-a", "fi-1", WireGuardIdentity.Generate(),
            NativeRetirementRequired: true));
        await ExpectFailureAsync(() => fixture.SignInAsync("account-b"));
        Check(fixture.Store.State!.Session.User.Id == "account-a" && vpn.Active,
            "Locked stored A session cannot be treated as missing and overwritten by B after an unconfirmed stop.");
        vpn.FailStop = false;
        await fixture.SignInAsync("account-b");
        Check(!vpn.Active && fixture.Store.State!.Session.User.Id == "account-b",
            "Locked A may be replaced by validated B only after conservative native retirement.");
    }

    private sealed class HiddenSessionStore(MemoryClientStateStore underlying) : IClientStateStore
    {
        public IVpnAccountIdentityStore AccountVpnIdentities => underlying.AccountVpnIdentities;
        public bool HasStoredSession => underlying.State is not null;
        public ClientStateAccessKind GetAccessState() => HasStoredSession ? ClientStateAccessKind.Locked : ClientStateAccessKind.Missing;
        public string GetOrCreateInstallationId() => underlying.GetOrCreateInstallationId();
        public NativeDeviceState? LoadDevice() => underlying.LoadDevice();
        public NativeClientState? Load() => null;
        public void Save(NativeClientState state) => underlying.Save(state);
        public void Clear() => underlying.Clear();
    }

    private sealed class ControlledVpnClient : IVpnControlClient
    {
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource StopEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource StopRelease { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool ThrowAfterActivation { get; set; }
        public bool FailStop { get; set; }
        public bool Active { get; private set; }
        public int Stops { get; private set; }
        public int Connects { get; private set; }
        public void SeedActive() => Active = true;
        public Task<VpnServiceResponse> GetStatusAsync(CancellationToken cancellationToken) => Task.FromResult(
            new VpnServiceResponse("status", true, Active ? new(VpnConnectionPhase.Connected, "fi-1", 1, null) : VpnConnectionSnapshot.Disconnected(), null));
        public async Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization, string privateKey, CancellationToken cancellationToken)
        {
            Connects++;
            Active = true;
            Entered.TrySetResult();
            await Release.Task;
            if (ThrowAfterActivation) throw new OperationCanceledException("Caller pipe closed after service admission.");
            return new("connect", true, new(VpnConnectionPhase.Connected, "fi-1", 1, null), null);
        }
        public async Task<VpnServiceResponse> DisconnectAsync(CancellationToken cancellationToken)
        {
            Stops++;
            StopEntered.TrySetResult();
            await StopRelease.Task;
            if (FailStop) throw new IOException("Service unreachable; retirement unconfirmed.");
            Active = false;
            return new("disconnect", true, VpnConnectionSnapshot.Disconnected(), null);
        }
    }

    private static void ExpectFailure(Action action)
    {
        try { action(); } catch (Exception error) when (error is IOException or JsonException or CryptographicException or InvalidOperationException) { return; }
        throw new InvalidOperationException("Expected fail-closed operation.");
    }
    private static async Task ExpectFailureAsync(Func<Task> action)
    {
        try { await action(); } catch (Exception error) when (error is IOException or VexApiException or NativeClientFlowException or OperationCanceledException) { return; }
        throw new InvalidOperationException("Expected fail-closed asynchronous operation.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture : IDisposable
    {
        public OwnerGuardServer Server { get; } = new();
        private readonly HttpClient _http;
        public FakeDeviceIdentityProvider IdentityProvider { get; } = new();
        public MemoryClientStateStore Store { get; }
        public NativeApiProxy Proxy { get; }
        public NativeClientCoordinator Coordinator { get; }
        private VexAuthSession _session = Session("account-a");

        public Fixture(IVpnAccountIdentityStore? identities = null, IVpnControlClient? vpn = null,
            Func<MemoryClientStateStore, IClientStateStore>? accessStore = null, bool signerAvailable = true)
        {
            Store = new(identities);
            _http = new HttpClient(Server) { BaseAddress = new Uri("https://api.example.test") };
            var realApi = new VexApiClient(_http, signerAvailable ? IdentityProvider : null);
            var (api, proxy) = NativeApiProxy.Wrap(new FakeNativeClientApi());
            Proxy = proxy;
            proxy.Overrides[nameof(INativeClientApi.LoginAsync)] = _ => Task.FromResult(_session);
            proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = args =>
                realApi.GetDevicesAsync((string)args[0]!, (CancellationToken)args[^1]!);
            proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = args =>
                realApi.RegisterNativeDeviceAsync((string)args[0]!, (string)args[1]!, (string)args[2]!,
                    (int)args[3]!, (string)args[4]!, (string)args[5]!, (string)args[6]!, (string)args[7]!, (CancellationToken)args[^1]!);
            proxy.Overrides[nameof(INativeClientApi.RotateManagedVpnKeyAsync)] = args =>
                realApi.RotateManagedVpnKeyAsync((string)args[0]!, (string)args[1]!,
                    (WireGuardIdentity)args[2]!, (CancellationToken)args[^1]!);
            Coordinator = new(api, accessStore?.Invoke(Store) ?? Store, vpn ?? new FakeVpnControlClient(), "1.0.0");
        }

        public Task SignInAsync(string user)
        {
            _session = Session(user);
            return Coordinator.SignInAsync(user + "@example.test", "password", CancellationToken.None);
        }

        private static VexAuthSession Session(string user) =>
            new(new(user, user + "@example.test", "active"), "access-" + user, DateTimeOffset.UtcNow.AddDays(30));
        public void Dispose() => _http.Dispose();
    }

    private sealed class OwnerGuardServer : HttpMessageHandler
    {
        private readonly Dictionary<(string Owner, string External), VpnDevice> _devices = new();
        private readonly Dictionary<string, string> _bindings = new(StringComparer.Ordinal);
        private readonly Dictionary<string, (string Owner, string External)> _creationHeaders = new(StringComparer.Ordinal);
        public List<(string Owner, string Installation, string Idempotency, string PublicKey)> Registrations { get; } = [];
        public List<(string Owner, string Device, WireGuardIdentity Identity)> Rotations { get; } = [];
        public HttpStatusCode? RegistrationError { get; set; }
        public HttpStatusCode? ChallengeError { get; set; }
        public object ErrorBody { get; set; } = new { code = "conflict", message = "device_rebind_required" };
        public List<(string Owner, string Installation)> Challenges { get; } = [];
        public List<(string Installation, string External, string Signer)> SignedRegistrations { get; } = [];
        public int DeviceCount => _devices.Count;
        public VpnDevice Device(string owner, string external) => _devices[(owner, external)];
        public void Seed(string owner, VpnDevice device, string? bindingOwner = null)
        {
            _devices[(owner, device.ExternalDeviceId!)] = device;
            if (bindingOwner is not null) _bindings["win-installation-1"] = bindingOwner;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var owner = request.Headers.Authorization!.Parameter!["access-".Length..];
            if (request.RequestUri!.AbsolutePath == "/v1/devices")
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(_devices
                    .Where(entry => entry.Key.Owner == owner).Select(entry => entry.Value).ToArray()) };
            using var payload = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            var root = payload.RootElement;
            if (request.RequestUri.AbsolutePath == "/v1/devices/identity-challenge")
            {
                if (ChallengeError is { } challengeError) return new(challengeError);
                Challenges.Add((owner, root.GetProperty("installation_id").GetString()!));
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(new {
                    id = "challenge-" + Challenges.Count, nonce = "nonce-" + Challenges.Count, purpose = "register" }) };
            }
            if (request.RequestUri.AbsolutePath == "/v1/vpn/rotate-key")
            {
                var id = root.GetProperty("device_id").GetString()!;
                var entry = _devices.Single(item => item.Key.Owner == owner && item.Value.Id == id);
                var key = root.GetProperty("public_key").GetString()!;
                var epoch = root.GetProperty("key_epoch").GetInt32();
                Check(epoch == entry.Value.PskEpoch + 1 || epoch == entry.Value.PskEpoch && key == entry.Value.PublicKey,
                    "Rotation must use authoritative proposed next epoch, or exact lost-response replay.");
                var updated = entry.Value with { PublicKey = key, PskEpoch = epoch };
                _devices[entry.Key] = updated;
                Rotations.Add((owner, id, new("private-not-sent", key, epoch)));
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { device = updated }) };
            }
            Check(request.RequestUri.AbsolutePath == "/v1/devices/register", "Unexpected registration fixture endpoint.");
            var installation = root.GetProperty("installation_id").GetString()!;
            var external = root.GetProperty("device_id").GetString()!;
            var publicKey = root.GetProperty("public_key").GetString()!;
            SignedRegistrations.Add((installation, external, root.GetProperty("identity_public_key").GetString()!));
            var epochValue = root.GetProperty("key_epoch").GetInt32();
            var idempotency = request.Headers.GetValues("Idempotency-Key").Single();
            Registrations.Add((owner, installation, idempotency, publicKey));
            // Actual server replayVerifiedNativeDeviceRegistration consults the
            // current row by creation header, rejecting a stale proposed epoch
            // before a fresh challenge can change that registration intent.
            if (_creationHeaders.TryGetValue(idempotency, out var prior) &&
                (prior.Owner != owner || _devices[prior].PublicKey != publicKey || _devices[prior].PskEpoch != epochValue))
                return new(HttpStatusCode.Conflict) { Content = JsonContent.Create(new { code = "conflict" }) };
            if (RegistrationError is { } error) return new(error) { Content = JsonContent.Create(ErrorBody) };
            if (_bindings.TryGetValue(installation, out var bindingOwner) && bindingOwner != owner)
                return new(HttpStatusCode.Conflict) { Content = JsonContent.Create(ErrorBody) };
            if (!_devices.TryGetValue((owner, external), out var device))
                device = LegacyDevice(owner, publicKey, epochValue, external);
            Check(device.PublicKey == publicKey, "Registration cannot overwrite an owned row without explicit rotation.");
            _devices[(owner, external)] = device;
            _bindings[installation] = owner;
            _creationHeaders.TryAdd(idempotency, (owner, external));
            return new(HttpStatusCode.Created) { Content = JsonContent.Create(new { device }) };
        }
    }
}

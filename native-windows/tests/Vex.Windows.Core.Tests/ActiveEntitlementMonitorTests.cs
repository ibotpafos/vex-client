using System.Net;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class ActiveEntitlementMonitorTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await CurrentRejectionDisconnectsAsync();
        await OutagesAndRequestDeadlinePreserveAdmissionAsync();
        await QueuedOldTokenCannotValidateAReplacementLoginAsync();
        await RejectionWaitingForVpnGateCannotDisconnectNewLoginAsync();
        await RejectionWaitingForVpnGateHonorsNewIntentAsync();
        await QueuedServerSwitchSupersedesRejectionAsync();
        await HelloLockCannotRevokeAdmissionAsync();
        await CallerCancellationPreservesAdmissionAsync();
        await CleanupFailureRemainsRetryableAsync();
        await CleanupCancellationRemainsRetryableAsync();
        await RefreshedTokenDenialIsEnforcedOnNextPollAsync();
        await AuthoritativeSessionRejectionDisconnectsAsync();
        await LockedMissingAndInactiveSessionsSkipValidationAsync();
    }

    private static async Task CurrentRejectionDisconnectsAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(fixture.DisconnectCalls == 1 && !fixture.VpnState.ConnectionDesired &&
            fixture.VpnState.HasExplicitConnectionIntent &&
            fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "A current unpaid entitlement did not revoke admission and confirm cleanup.");
        Check(fixture.BillingTokens.SequenceEqual(["old-account-token"]),
            "The monitor did not validate the captured session.");
    }

    private static async Task OutagesAndRequestDeadlinePreserveAdmissionAsync()
    {
        foreach (var error in new Exception[] { new HttpRequestException("offline"), new IOException("offline") })
        {
            var fixture = new Fixture();
            fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
                Task.FromException<VexEntitlement>(error);
            await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
            fixture.AssertAdmissionPreserved("A control-plane outage changed the working tunnel.");
        }

        var deadlineFixture = new Fixture(TimeSpan.FromMilliseconds(50));
        var entered = Signal();
        deadlineFixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = args =>
            WaitUntilCanceledAsync((CancellationToken)args[1]!, entered);
        var checking = deadlineFixture.Monitor.CheckAsync(CancellationToken.None);
        await entered.Task.WaitAsync(Deadline);
        await checking.WaitAsync(Deadline);
        deadlineFixture.AssertAdmissionPreserved("The bounded entitlement request deadline revoked admission.");

        var lateFixture = new Fixture(TimeSpan.FromMilliseconds(50));
        lateFixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = args =>
            ReturnDeniedAfterDeadlineAsync((CancellationToken)args[1]!);
        await lateFixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        lateFixture.AssertAdmissionPreserved("A denial delivered after the request deadline revoked admission.");
    }

    private static async Task QueuedOldTokenCannotValidateAReplacementLoginAsync()
    {
        var fixture = new Fixture();
        var entered = Signal();
        var release = new TaskCompletionSource<IReadOnlyList<VpnLocation>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ =>
        {
            entered.TrySetResult();
            return release.Task;
        };
        fixture.DenyAccess();
        var holding = fixture.Coordinator.GetLocationsAsync(CancellationToken.None);
        await entered.Task.WaitAsync(Deadline);
        var login = fixture.Coordinator.AcceptAuthenticatedSessionAsync(NewSession(), CancellationToken.None);
        var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
        Check(!login.IsCompleted && !checking.IsCompleted,
            "The stale-token regression must queue login and validation behind the coordinator gate.");
        release.TrySetResult(fixture.Api.Locations);
        await holding.WaitAsync(Deadline);
        await login.WaitAsync(Deadline);
        await checking.WaitAsync(Deadline);
        fixture.AssertAdmissionPreserved("A queued old-token validation changed the replacement login's tunnel.");
        Check(fixture.BillingTokens.Count == 0 && fixture.Store.State!.Session.AccessToken == "new-account-token",
            "An old-token monitor validated or mutated the newly authenticated account.");
    }

    private static async Task RejectionWaitingForVpnGateCannotDisconnectNewLoginAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        await using var held = await GateHold.AcquireAsync(fixture.VpnState);
        var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
        Check(!checking.IsCompleted && fixture.BillingTokens.Count == 1,
            "A current rejection must wait behind the existing VPN operation.");
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(NewSession(), CancellationToken.None).WaitAsync(Deadline);
        await held.ReleaseAsync();
        await checking.WaitAsync(Deadline);
        fixture.AssertAdmissionPreserved("An old rejection waiting for the VPN gate disconnected a new login.");
        Check(fixture.Store.State!.Session.AccessToken == "new-account-token",
            "Cleanup of a stale rejection changed the replacement session.");
    }

    private static async Task RejectionWaitingForVpnGateHonorsNewIntentAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        await using var held = await GateHold.AcquireAsync(fixture.VpnState);
        var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
        var oldVersion = fixture.VpnState.ConnectionIntentVersion;
        fixture.VpnState.MarkConnectionDesired(true);
        var newVersion = fixture.VpnState.ConnectionIntentVersion;
        await held.ReleaseAsync();
        await checking.WaitAsync(Deadline);
        fixture.AssertAdmissionPreserved("An old admission rejection overwrote a newer Connect intent.");
        Check(newVersion > oldVersion && fixture.VpnState.ConnectionIntentVersion == newVersion,
            "Ignoring a stale rejection changed the newer intent version.");
        Check(!fixture.VpnState.TryMarkConnectionUndesired(oldVersion) && fixture.VpnState.ConnectionDesired,
            "The conditional revocation accepted a superseded intent version.");
    }

    private static async Task HelloLockCannotRevokeAdmissionAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        await using var held = await GateHold.AcquireAsync(fixture.VpnState);
        var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
        fixture.StateAccess.Locked = true;
        await held.ReleaseAsync();
        await checking.WaitAsync(Deadline);
        fixture.AssertAdmissionPreserved("A Windows Hello lock while waiting for cleanup revoked the tunnel.");
        Check(fixture.Coordinator.CurrentState is null &&
            fixture.Coordinator.CurrentStateAccess == ClientStateAccessKind.Locked,
            "The lock regression requires a hidden rather than deleted protected session.");

        fixture.StateAccess.Locked = false;
        fixture.Now += TimeSpan.FromMinutes(1);
        await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(fixture.DisconnectCalls == 1 && !fixture.VpnState.ConnectionDesired,
            "Unlocking prevented the next authoritative rejection from revoking admission.");
    }

    private static async Task QueuedServerSwitchSupersedesRejectionAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        await using var held = await GateHold.AcquireAsync(fixture.VpnState);
        var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
        var oldVersion = fixture.VpnState.ConnectionIntentVersion;
        var switched = fixture.VpnState.RunConnectionAsync(_ => Task.FromResult(new VpnServiceResponse(
            "new-server", true, new(VpnConnectionPhase.Connected, "de-1", 9, null), null)),
            CancellationToken.None, onlyWhenIdle: true);
        var admittedVersion = fixture.VpnState.ConnectionIntentVersion;
        Check(admittedVersion > oldVersion && !checking.IsCompleted && !switched.IsCompleted,
            "The server switch must record new intent while both operations wait for the VPN gate.");
        var busySelectorRan = false;
        try
        {
            await fixture.VpnState.RunConnectionAsync(_ =>
            {
                busySelectorRan = true;
                return Task.FromResult(Disconnected());
            }, CancellationToken.None, onlyWhenIdle: true).WaitAsync(Deadline);
            throw new InvalidOperationException("A busy server selector was admitted.");
        }
        catch (NativeClientFlowException error) when (error.Code == "vpn_operation_in_progress") { }
        Check(!busySelectorRan && fixture.VpnState.ConnectionIntentVersion == admittedVersion &&
            fixture.VpnState.ConnectionDesired,
            "A rejected busy server selector changed connection intent.");
        await held.ReleaseAsync();
        await checking.WaitAsync(Deadline);
        await switched.WaitAsync(Deadline);
        Check(fixture.DisconnectCalls == 0 && fixture.VpnState.ConnectionDesired &&
            fixture.VpnState.ConnectionIntentVersion == admittedVersion &&
            fixture.VpnState.Snapshot is { Phase: VpnConnectionPhase.Connected, LocationId: "de-1", Sequence: 9 },
            "The old entitlement rejection cut off or overwrote the newly admitted server switch.");
    }

    private static async Task CallerCancellationPreservesAdmissionAsync()
    {
        var fixture = new Fixture();
        var entered = Signal();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = args =>
            WaitUntilCanceledAsync((CancellationToken)args[1]!, entered);
        using var cancellation = new CancellationTokenSource();
        var checking = fixture.Monitor.CheckAsync(cancellation.Token);
        await entered.Task.WaitAsync(Deadline);
        cancellation.Cancel();
        await ExpectCancellationAsync(checking);
        fixture.AssertAdmissionPreserved("Caller cancellation of validation changed the working tunnel.");

        var gateFixture = new Fixture();
        gateFixture.DenyAccess();
        await using var held = await GateHold.AcquireAsync(gateFixture.VpnState);
        using var queuedCancellation = new CancellationTokenSource();
        var queued = gateFixture.Monitor.CheckAsync(queuedCancellation.Token);
        queuedCancellation.Cancel();
        await ExpectCancellationAsync(queued);
        gateFixture.AssertAdmissionPreserved("Canceling a queued revocation changed intent or status.");
    }

    private static async Task CleanupFailureRemainsRetryableAsync()
    {
        foreach (var throws in new[] { false, true })
        {
            var fixture = new Fixture();
            fixture.DenyAccess();
            fixture.Disconnect = _ => throws
                ? Task.FromException<VpnServiceResponse>(new IOException("service unavailable"))
                : Task.FromResult(new VpnServiceResponse("failed", false,
                    VpnConnectionSnapshot.Disconnected(), "vpn_service_unavailable"));
            var checking = fixture.Monitor.CheckAsync(CancellationToken.None);
            if (throws)
            {
                try { await checking.WaitAsync(Deadline); throw new InvalidOperationException("Expected cleanup failure."); }
                catch (IOException) { }
            }
            else await checking.WaitAsync(Deadline);
            Check(!fixture.VpnState.ConnectionDesired && fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Error &&
                VpnRecoveryPolicy.RequiresDisconnect(fixture.VpnState.Snapshot),
                "A failed admission cleanup lost the state needed by the background retry.");
            await fixture.VpnState.DisconnectIfUnwantedAsync(_ => Task.FromResult(Disconnected()),
                CancellationToken.None).WaitAsync(Deadline);
            Check(fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Disconnected,
                "Background enforcement could not retry an unconfirmed admission cleanup.");
        }
    }

    private static async Task CleanupCancellationRemainsRetryableAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        var entered = Signal();
        fixture.Disconnect = async token =>
        {
            entered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Disconnected();
        };
        using var cancellation = new CancellationTokenSource();
        var checking = fixture.Monitor.CheckAsync(cancellation.Token);
        await entered.Task.WaitAsync(Deadline);
        cancellation.Cancel();
        await ExpectCancellationAsync(checking);
        Check(!fixture.VpnState.ConnectionDesired &&
            fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Connected &&
            VpnRecoveryPolicy.RequiresDisconnect(fixture.VpnState.Snapshot),
            "Canceled cleanup lost its unwanted tunnel evidence or replaced it with a false error.");
        await fixture.VpnState.DisconnectIfUnwantedAsync(_ => Task.FromResult(Disconnected()),
            CancellationToken.None).WaitAsync(Deadline);
        Check(fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "Caller cancellation prevented a later cleanup retry.");
    }

    private static async Task RefreshedTokenDenialIsEnforcedOnNextPollAsync()
    {
        var fixture = new Fixture();
        fixture.DenyAccess();
        var state = fixture.Store.State!;
        fixture.Store.Save(state with
        {
            Session = state.Session with { ExpiresAt = fixture.Now.AddSeconds(-1) },
        });
        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            Task.FromResult(new VexAuthSession(fixture.Store.State!.Session.User,
                "refreshed-account-token", fixture.Now.AddDays(30)));
        await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        fixture.AssertAdmissionPreserved("A validation-driven token change bypassed the conservative session fence.");
        fixture.Now += TimeSpan.FromMinutes(1);
        await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(fixture.DisconnectCalls == 1 && !fixture.VpnState.ConnectionDesired &&
            fixture.BillingTokens.SequenceEqual(["refreshed-account-token", "refreshed-account-token"]),
            "The next poll failed to enforce the current denial after validation refreshed its session.");
    }

    private static async Task AuthoritativeSessionRejectionDisconnectsAsync()
    {
        var fixture = new Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
            Task.FromException<VexEntitlement>(new VexApiException(HttpStatusCode.Unauthorized, "unauthorized"));
        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            Task.FromException<VexAuthSession>(new VexApiException(HttpStatusCode.Unauthorized, "unauthorized"));
        await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(fixture.Store.State is null && fixture.Coordinator.CurrentStateAccess == ClientStateAccessKind.Missing &&
            fixture.DisconnectCalls == 1 && !fixture.VpnState.ConnectionDesired &&
            fixture.VpnState.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "An authoritative current-session rejection left its tunnel admitted.");
    }

    private static async Task LockedMissingAndInactiveSessionsSkipValidationAsync()
    {
        foreach (var kind in new[] { "locked", "missing", "disconnected" })
        {
            var fixture = new Fixture();
            fixture.DenyAccess();
            if (kind == "locked") fixture.StateAccess.Locked = true;
            else if (kind == "missing") fixture.Store.Clear();
            else fixture.VpnState.Apply(Disconnected());
            var original = fixture.VpnState.Snapshot;
            await fixture.Monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
            Check(fixture.BillingTokens.Count == 0 && fixture.DisconnectCalls == 0 &&
                fixture.VpnState.ConnectionDesired && fixture.VpnState.Snapshot == original,
                "Unavailable protected state or an inactive tunnel triggered validation or changed VPN intent.");
        }
    }

    private static async Task<VexEntitlement> WaitUntilCanceledAsync(CancellationToken token,
        TaskCompletionSource entered)
    {
        entered.TrySetResult();
        await Task.Delay(Timeout.InfiniteTimeSpan, token);
        return FakeNativeClientApi.NoVpnEntitlement;
    }

    private static async Task<VexEntitlement> ReturnDeniedAfterDeadlineAsync(CancellationToken token)
    {
        try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        return FakeNativeClientApi.NoVpnEntitlement;
    }

    private static VexAuthSession NewSession() => new(new("other-user", "other@example.com", "active"),
        "new-account-token", DateTimeOffset.UtcNow.AddDays(30));

    private static VpnServiceResponse Disconnected() =>
        new("disconnected", true, VpnConnectionSnapshot.Disconnected(8), null);

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static async Task ExpectCancellationAsync(Task task)
    {
        try { await task.WaitAsync(Deadline); throw new InvalidOperationException("Expected caller cancellation."); }
        catch (OperationCanceledException) { }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture
    {
        public FakeNativeClientApi Api { get; } = new();
        public MemoryClientStateStore Store { get; } = new();
        public LockableStateStore StateAccess { get; }
        public NativeApiProxy Proxy { get; }
        public NativeClientCoordinator Coordinator { get; }
        public VpnUiStateService VpnState { get; }
        public ActiveEntitlementMonitor Monitor { get; }
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public List<string> BillingTokens { get; } = [];
        public int DisconnectCalls { get; private set; }
        public Func<CancellationToken, Task<VpnServiceResponse>> Disconnect { get; set; } =
            _ => Task.FromResult(Disconnected());

        public Fixture(TimeSpan? timeout = null)
        {
            var (api, proxy) = NativeApiProxy.Wrap(Api);
            Proxy = proxy;
            Store.Save(new NativeClientState(
                new(new("user-1", "user@example.com", "active"), "old-account-token", Now.AddDays(30)),
                "win-installation-1", "old-device", "fi-1", WireGuardIdentity.Generate()));
            StateAccess = new LockableStateStore(Store);
            Coordinator = new NativeClientCoordinator(api, StateAccess, new FakeVpnControlClient(), "1.0.0", () => Now);
            VpnState = new VpnUiStateService(_ => Task.FromResult(new VpnServiceResponse("status", true,
                new(VpnConnectionPhase.Connected, "fi-1", 7, null), null)));
            VpnState.Apply(new VpnServiceResponse("connected", true,
                new(VpnConnectionPhase.Connected, "fi-1", 7, null), null));
            VpnState.MarkConnectionDesired(true);
            Monitor = new ActiveEntitlementMonitor(Coordinator, VpnState, token =>
            {
                DisconnectCalls++;
                return Disconnect(token);
            }, () => Now, timeout ?? TimeSpan.FromSeconds(15));
        }

        public void DenyAccess() => Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = args =>
        {
            BillingTokens.Add((string)args[0]!);
            return Task.FromResult(FakeNativeClientApi.NoVpnEntitlement);
        };

        public void AssertAdmissionPreserved(string message) => Check(DisconnectCalls == 0 &&
            VpnState.ConnectionDesired && VpnState.Snapshot.Phase == VpnConnectionPhase.Connected &&
            VpnState.Snapshot.ErrorCode is null && VpnState.Snapshot.Sequence == 7, message);
    }

    private sealed class LockableStateStore(MemoryClientStateStore underlying) : IClientStateStore
    {
        public bool Locked { get; set; }
        public ClientStateAccessKind GetAccessState() => Locked ? ClientStateAccessKind.Locked : underlying.GetAccessState();
        public string GetOrCreateInstallationId() => underlying.GetOrCreateInstallationId();
        public NativeDeviceState? LoadDevice() => underlying.LoadDevice();
        public NativeClientState? Load() => Locked ? null : underlying.Load();
        public void Save(NativeClientState state) => underlying.Save(state);
        public void Clear() => underlying.Clear();
    }

    private sealed class GateHold : IAsyncDisposable
    {
        private readonly TaskCompletionSource _entered = Signal();
        private readonly TaskCompletionSource _release = Signal();
        private Task _holding = Task.CompletedTask;

        public static async Task<GateHold> AcquireAsync(VpnUiStateService state)
        {
            var hold = new GateHold();
            hold._holding = state.RunAsync(async _ =>
            {
                hold._entered.TrySetResult();
                await hold._release.Task.WaitAsync(Deadline);
                return new VpnServiceResponse("gate", true, state.Snapshot, null);
            }, CancellationToken.None);
            await hold._entered.Task.WaitAsync(Deadline);
            return hold;
        }

        public async Task ReleaseAsync()
        {
            _release.TrySetResult();
            await _holding.WaitAsync(Deadline);
        }

        public async ValueTask DisposeAsync() => await ReleaseAsync();
    }
}

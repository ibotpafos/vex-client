using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;

internal static class RealtimeScopeIsolationTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await QueuedOldSessionEventsCannotMutateNewLoginAsync();
        await MatchingSessionEventsKeepSupportedBehaviorAsync();
    }

    private static async Task QueuedOldSessionEventsCannotMutateNewLoginAsync()
    {
        var api = new FakeNativeClientApi();
        var (native, proxy) = NativeApiProxy.Wrap(api);
        var store = new MemoryClientStateStore();
        store.Save(ReadyState(api));
        var coordinator = new NativeClientCoordinator(native, store, new FakeVpnControlClient(), "1.0.0");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var locations = new TaskCompletionSource<IReadOnlyList<VpnLocation>>(TaskCreationOptions.RunContinuationsAsynchronously);
        proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ =>
        {
            entered.TrySetResult();
            return locations.Task;
        };
        var scopeEvents = 0;
        coordinator.ProfileScopeChanged += (_, _) => scopeEvents++;
        var holdingGate = coordinator.GetLocationsAsync(CancellationToken.None);
        await entered.Task.WaitAsync(Deadline);
        var oldToken = store.State!.Session.AccessToken;
        var newSession = new VexAuthSession(new("other-user", "other@example.com", "active"),
            "new-account-token", DateTimeOffset.UtcNow.AddDays(30));
        var login = coordinator.AcceptAuthenticatedSessionAsync(newSession, CancellationToken.None);
        Task[] staleEvents =
        [
            coordinator.InvalidateCachedEntitlementAsync(CancellationToken.None, oldToken),
            coordinator.InvalidateProfileAsync(CancellationToken.None, oldToken),
            coordinator.ValidateEntitlementAsync(CancellationToken.None, oldToken),
        ];
        Check(!login.IsCompleted && staleEvents.All(task => !task.IsCompleted),
            "The regression requires the login and stale events to wait behind the coordinator gate.");
        locations.TrySetResult(api.Locations);
        await holdingGate.WaitAsync(Deadline);
        await login.WaitAsync(Deadline);
        var accepted = store.State;
        var eventsAfterLogin = scopeEvents;
        foreach (var stale in staleEvents) await ExpectChangedSessionAsync(stale);
        Check(ReferenceEquals(store.State, accepted) && store.State is { VpnProvisioningPending: true } &&
            store.State.Session == newSession && api.EntitlementCalls == 0 && api.ProfileCalls == 0 &&
            scopeEvents == eventsAfterLogin,
            "Queued old-token updates mutated the new account, fetched its billing, or cancelled its profile scope.");
        proxy.Overrides.Remove(nameof(INativeClientApi.GetLocationsAsync));
        Check((await coordinator.GetLocationsAsync(CancellationToken.None).WaitAsync(Deadline)).Count > 0,
            "Rejected stale events retained the coordinator gate.");
    }

    private static async Task MatchingSessionEventsKeepSupportedBehaviorAsync()
    {
        var api = new FakeNativeClientApi();
        var store = new MemoryClientStateStore();
        store.Save(ReadyState(api));
        var coordinator = new NativeClientCoordinator(api, store, new FakeVpnControlClient(), "1.0.0");
        var token = store.State!.Session.AccessToken;
        await coordinator.InvalidateCachedEntitlementAsync(CancellationToken.None, token);
        Check(store.State!.CachedEntitlementCheckedAt is null && store.State.CachedEntitlementValidUntil is null,
            "An update from the current session did not invalidate entitlement freshness.");
        await coordinator.InvalidateProfileAsync(CancellationToken.None, token);
        Check(store.State!.CachedAuthorization is null && store.State.CachedProfileVersion is null,
            "An update from the current session did not invalidate cached profile authority.");
        await coordinator.ValidateEntitlementAsync(CancellationToken.None, token);
        Check(api.EntitlementCalls == 1 && store.State!.CachedEntitlement?.HasPaidAccess == true &&
            store.State.CachedEntitlementValidUntil > DateTimeOffset.UtcNow,
            "A current-session update could not refresh its authoritative paid access.");
    }

    private static NativeClientState ReadyState(FakeNativeClientApi api) => new(
        new(new("user-1", "user@example.com", "active"), "old-account-token", DateTimeOffset.UtcNow.AddDays(30)),
        "win-installation-1", "old-device", "fi-1", WireGuardIdentity.Generate(),
        CachedProfileVersion: 1,
        CachedAuthorization: new("test-key", "ECDSA_P256_SHA256_DER", "old-payload", "old-signature"),
        CachedEntitlement: api.Entitlement, CachedEntitlementCheckedAt: DateTimeOffset.UtcNow,
        CachedEntitlementValidUntil: DateTimeOffset.UtcNow.AddHours(1));

    private static async Task ExpectChangedSessionAsync(Task task)
    {
        try
        {
            await task.WaitAsync(Deadline);
            throw new InvalidOperationException("The queued stale event was accepted for a new session.");
        }
        catch (NativeClientFlowException error) when (error.Code == "session_changed") { }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

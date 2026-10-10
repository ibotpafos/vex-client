using Vex.Windows.App.Auth;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Session;

internal static class NativeAuthServiceTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await BrowserCallbackProvisionsAndClearsChallengeAsync();
        await PersistedChallengeCompletesAfterRestartAsync();
        await CancellationDuringExchangeCannotProvisionAsync(lateFailure: false);
        await CancellationDuringExchangeCannotProvisionAsync(lateFailure: true);
        await CancellationDuringRegistrationCannotSaveAsync();
        await CancellationDuringLocationsCannotRegisterAsync();
        await FreshRegistrationSurvivesOldCallbackCompletionAsync();
        await StaleCallbackPreservesFreshChallengeAsync();
        await QueuedStaleCallbackPreservesFreshChallengeAsync();
        await CancellationSurvivesChallengeClearFailureAsync();
        await BrowserLaunchFailureSurvivesChallengeClearFailureAsync();
    }

    private static async Task BrowserCallbackProvisionsAndClearsChallengeAsync()
    {
        var fixture = new Fixture();
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Register, CancellationToken.None);
        var pending = RequireChallenge(fixture);
        Check(fixture.Auth.IsWaitingForBrowserAuth && fixture.BrowserUris.Count == 1,
            "Browser registration did not retain its active PKCE challenge.");
        Check(fixture.BrowserUris[0].Query.Contains("mode=register", StringComparison.Ordinal),
            "Registration launched the login flow.");

        await fixture.Auth.HandleProtocolActivationAsync(Callback(pending), CancellationToken.None);

        Check(fixture.Api.RegisterCalls == 1 && fixture.Store.SaveCount == 1 &&
            fixture.Store.State?.Session.User.Email == "user@example.com",
            "A valid browser callback did not provision and persist its session exactly once.");
        Check(fixture.Pkce.Pending is null && !fixture.Auth.IsWaitingForBrowserAuth &&
            fixture.Auth.Error is null && !string.IsNullOrEmpty(fixture.Auth.Notice),
            "Successful browser login retained its pending challenge or error.");
    }

    private static async Task CancellationDuringExchangeCannotProvisionAsync(bool lateFailure)
    {
        var fixture = new Fixture();
        var started = Signal();
        var response = Result<VexAuthSession>();
        CancellationToken exchangeToken = default;
        fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = args =>
        {
            exchangeToken = (CancellationToken)args[^1]!;
            started.TrySetResult();
            return response.Task; // Deliberately ignores the supplied cancellation token.
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var callback = fixture.Auth.HandleProtocolActivationAsync(Callback(RequireChallenge(fixture)),
            CancellationToken.None);
        await started.Task.WaitAsync(Deadline);

        fixture.Auth.CancelBrowserAuth();
        var cancellationNotice = fixture.Auth.Notice;
        Check(exchangeToken.IsCancellationRequested && !fixture.Auth.IsWaitingForBrowserAuth,
            "Cancel did not invalidate the in-flight browser exchange.");
        if (lateFailure)
            response.TrySetException(new HttpRequestException("Old browser response failed after cancellation."));
        else
            response.TrySetResult(Session());
        await callback.WaitAsync(Deadline);

        Check(fixture.Api.RegisterCalls == 0 && fixture.Store.SaveCount == 0 && fixture.Store.State is null,
            "A cancelled browser exchange registered a device or saved a session.");
        Check(fixture.Auth.Notice == cancellationNotice && fixture.Auth.Error is null &&
            !fixture.Auth.IsWaitingForBrowserAuth,
            "A late exchange result overwrote the cancellation status.");
    }

    private static async Task PersistedChallengeCompletesAfterRestartAsync()
    {
        var pending = new PendingPkceChallenge(new string('v', 64), "persisted-browser-state");
        var fixture = new Fixture(pending);
        Check(!fixture.Auth.IsWaitingForBrowserAuth && fixture.BrowserUris.Count == 0,
            "The restart fixture unexpectedly launched a fresh browser attempt.");

        await fixture.Auth.HandleProtocolActivationAsync(Callback(pending), CancellationToken.None);

        Check(fixture.Api.RegisterCalls == 1 && fixture.Store.SaveCount == 1 && fixture.Pkce.Pending is null &&
            fixture.Auth.Error is null && !fixture.Auth.IsWaitingForBrowserAuth,
            "A valid persisted PKCE callback could not finish after application restart.");
    }

    private static async Task CancellationDuringRegistrationCannotSaveAsync()
    {
        var fixture = new Fixture();
        var started = Signal();
        var response = Result<VpnDevice>();
        var registrations = 0;
        CancellationToken registrationToken = default;
        fixture.Proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = args =>
        {
            registrations++;
            registrationToken = (CancellationToken)args[^1]!;
            started.TrySetResult();
            return response.Task; // The registration server can complete after local cancellation.
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var callback = fixture.Auth.HandleProtocolActivationAsync(Callback(RequireChallenge(fixture)),
            CancellationToken.None);
        await started.Task.WaitAsync(Deadline);

        fixture.Pkce.BeforeClear = () => Check(registrationToken.IsCancellationRequested,
            "Cancellation attempted disk cleanup before stopping in-flight provisioning.");
        fixture.Auth.CancelBrowserAuth();
        var cancellationNotice = fixture.Auth.Notice;
        Check(registrationToken.IsCancellationRequested,
            "Cancel did not reach the authenticated provisioning operation.");
        response.TrySetResult(new VpnDevice("late-device", "Windows", "active", "public-key"));
        await callback.WaitAsync(Deadline);
        await DrainProvisioningAsync(fixture);

        Check(registrations == 1 && fixture.Store.SaveCount == 0 && fixture.Store.State is null,
            "A registration completing after cancellation saved an authenticated session.");
        Check(fixture.Pkce.Pending is null && fixture.Auth.Notice == cancellationNotice &&
            fixture.Auth.Error is null && !fixture.Auth.IsWaitingForBrowserAuth,
            "Late registration overwrote cancellation or restored its challenge.");
    }

    private static async Task CancellationDuringLocationsCannotRegisterAsync()
    {
        var fixture = new Fixture();
        var started = Signal();
        var locations = Result<IReadOnlyList<VpnLocation>>();
        CancellationToken locationsToken = default;
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = args =>
        {
            locationsToken = (CancellationToken)args[^1]!;
            started.TrySetResult();
            return locations.Task;
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var callback = fixture.Auth.HandleProtocolActivationAsync(Callback(RequireChallenge(fixture)),
            CancellationToken.None);
        await started.Task.WaitAsync(Deadline);

        fixture.Auth.CancelBrowserAuth();
        var cancellationNotice = fixture.Auth.Notice;
        Check(locationsToken.IsCancellationRequested,
            "Cancel did not reach authenticated location discovery.");
        locations.TrySetResult(fixture.Api.Locations);
        await callback.WaitAsync(Deadline);
        await DrainProvisioningAsync(fixture);

        Check(fixture.Api.RegisterCalls == 0 && fixture.Store.SaveCount == 0 && fixture.Store.State is null,
            "Location discovery completing after cancellation still registered or saved the session.");
        Check(fixture.Auth.Notice == cancellationNotice && fixture.Auth.Error is null,
            "Cancelled location discovery overwrote the cancellation status.");
    }

    private static async Task FreshRegistrationSurvivesOldCallbackCompletionAsync()
    {
        var fixture = new Fixture();
        var started = Signal();
        var response = Result<VexAuthSession>();
        fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = _ =>
        {
            started.TrySetResult();
            return response.Task;
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var oldPending = RequireChallenge(fixture);
        var oldCallback = fixture.Auth.HandleProtocolActivationAsync(Callback(oldPending), CancellationToken.None);
        await started.Task.WaitAsync(Deadline);

        fixture.Auth.CancelBrowserAuth();
        var freshAttempt = fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Register, CancellationToken.None);
        // WaitAsync on the exchange lets a fresh attempt start even when the
        // old HTTP operation does not observe cancellation.
        await freshAttempt.WaitAsync(Deadline);
        var freshPending = RequireChallenge(fixture);
        var freshNotice = fixture.Auth.Notice;
        response.TrySetResult(Session());
        await oldCallback.WaitAsync(Deadline);

        Check(freshPending.State != oldPending.State && fixture.Pkce.Pending == freshPending &&
            fixture.Auth.IsWaitingForBrowserAuth && fixture.Auth.Notice == freshNotice && fixture.Auth.Error is null,
            "An old callback cleared the fresh registration challenge or status.");
        Check(fixture.BrowserUris.Count == 2 && fixture.Api.RegisterCalls == 0 && fixture.Store.SaveCount == 0,
            "Starting fresh registration unexpectedly provisioned the old login.");
    }

    private static async Task StaleCallbackPreservesFreshChallengeAsync()
    {
        var fixture = new Fixture();
        var exchanges = 0;
        fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = _ =>
        {
            exchanges++;
            return Task.FromResult(Session());
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var oldPending = RequireChallenge(fixture);
        fixture.Auth.CancelBrowserAuth();
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Register, CancellationToken.None);
        var freshPending = RequireChallenge(fixture);
        var freshNotice = fixture.Auth.Notice;

        await fixture.Auth.HandleProtocolActivationAsync(Callback(oldPending), CancellationToken.None);

        Check(exchanges == 0 && fixture.Api.RegisterCalls == 0 && fixture.Store.SaveCount == 0,
            "A callback for the old state reached authentication or provisioning.");
        Check(fixture.Pkce.Pending == freshPending && fixture.Auth.IsWaitingForBrowserAuth &&
            fixture.Auth.Notice == freshNotice && fixture.Auth.Error is null,
            "A stale state callback consumed or invalidated the current registration.");
    }

    private static async Task QueuedStaleCallbackPreservesFreshChallengeAsync()
    {
        var fixture = new Fixture();
        var started = Signal();
        var registration = Result<VpnDevice>();
        var exchanges = 0;
        fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = _ =>
        {
            exchanges++;
            return Task.FromResult(Session());
        };
        fixture.Proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = _ =>
        {
            started.TrySetResult();
            return registration.Task;
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var oldPending = RequireChallenge(fixture);
        var oldCallback = fixture.Auth.HandleProtocolActivationAsync(Callback(oldPending), CancellationToken.None);
        await started.Task.WaitAsync(Deadline);

        fixture.Auth.CancelBrowserAuth();
        var freshAttempt = fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Register, CancellationToken.None);
        var staleCallback = fixture.Auth.HandleProtocolActivationAsync(Callback(oldPending), CancellationToken.None);
        registration.TrySetResult(new VpnDevice("late-device", "Windows", "active", "public-key"));
        await Task.WhenAll(oldCallback, freshAttempt, staleCallback).WaitAsync(Deadline);
        await DrainProvisioningAsync(fixture);

        Check(RequireChallenge(fixture).State != oldPending.State && fixture.Auth.IsWaitingForBrowserAuth &&
            fixture.Auth.Error is null && fixture.Auth.Notice?.Contains("регистрац", StringComparison.OrdinalIgnoreCase) == true,
            "A queued old callback overwrote the next registration attempt.");
        Check(exchanges == 1 && fixture.Store.SaveCount == 0,
            "A queued callback reused the old exchange or saved the cancelled provisioning result.");
    }

    private static async Task CancellationSurvivesChallengeClearFailureAsync()
    {
        var fixture = new Fixture();
        var exchanges = 0;
        fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = _ =>
        {
            exchanges++;
            return Task.FromResult(Session());
        };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var oldPending = RequireChallenge(fixture);
        fixture.Pkce.ClearError = new IOException("PKCE cache is read-only.");

        fixture.Auth.CancelBrowserAuth();
        var cancellationNotice = fixture.Auth.Notice;
        var cancellationError = fixture.Auth.Error;
        Check(!fixture.Auth.IsWaitingForBrowserAuth && !string.IsNullOrWhiteSpace(cancellationError),
            "Failed challenge cleanup either kept the attempt active or hid the storage error.");
        Check(fixture.Pkce.Pending == oldPending,
            "The failing storage fake did not retain the challenge needed for this regression.");

        await fixture.Auth.HandleProtocolActivationAsync(Callback(oldPending), CancellationToken.None);

        Check(exchanges == 0 && fixture.Api.RegisterCalls == 0 && fixture.Store.SaveCount == 0,
            "A challenge left on disk by failed cancellation cleanup was accepted again.");
        Check(!fixture.Auth.IsWaitingForBrowserAuth && fixture.Auth.Notice == cancellationNotice &&
            fixture.Auth.Error == cancellationError,
            "A callback after failed cleanup overwrote the invalidated attempt's status.");
    }

    private static async Task BrowserLaunchFailureSurvivesChallengeClearFailureAsync()
    {
        foreach (var throws in new[] { false, true })
        {
            var fixture = new Fixture();
            var exchanges = 0;
            fixture.Proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = _ =>
            {
                exchanges++;
                return Task.FromResult(Session());
            };
            fixture.Pkce.ClearError = new IOException("PKCE cache is read-only.");
            fixture.LaunchOverride = _ => throws
                ? Task.FromException<bool>(new InvalidOperationException("Browser activation failed."))
                : Task.FromResult(false);

            await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None).WaitAsync(Deadline);
            var retainedChallenge = RequireChallenge(fixture);
            var failureError = fixture.Auth.Error;
            Check(!fixture.Auth.IsWaitingForBrowserAuth && !string.IsNullOrWhiteSpace(failureError),
                "Browser launch failure and failed cleanup left an active attempt or escaped the auth flow.");

            await fixture.Auth.HandleProtocolActivationAsync(Callback(retainedChallenge), CancellationToken.None);

            Check(exchanges == 0 && fixture.Store.SaveCount == 0 && fixture.Auth.Error == failureError &&
                !fixture.Auth.IsWaitingForBrowserAuth,
                "An unsuccessfully launched browser attempt was revived from its retained challenge.");
        }
    }

    private static async Task DrainProvisioningAsync(Fixture fixture)
    {
        // The auth callback can return on cancellation while an HTTP operation
        // ignoring its token still holds the coordinator's gate. Entering that
        // gate proves the detached operation finished before we inspect saves.
        using var deadline = new CancellationTokenSource(Deadline);
        try
        {
            await fixture.Coordinator.ValidateEntitlementAsync(deadline.Token);
        }
        catch (NativeClientFlowException error) when (error.Code == "sign_in_required") { }
    }

    private static PendingPkceChallenge RequireChallenge(Fixture fixture) =>
        fixture.Pkce.Pending ?? throw new InvalidOperationException("Expected a pending PKCE challenge.");

    private static Uri Callback(PendingPkceChallenge challenge) =>
        new($"vexguard://auth/callback?code=browser-code&state={Uri.EscapeDataString(challenge.State)}");

    private static VexAuthSession Session() =>
        new(new VexUser("user-1", "user@example.com", "active"), "browser-access-token",
            new DateTimeOffset(2099, 8, 1, 0, 0, 0, TimeSpan.Zero));

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static TaskCompletionSource<T> Result<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture
    {
        public FakeNativeClientApi Api { get; } = new();
        public NativeApiProxy Proxy { get; }
        public CountingClientStateStore Store { get; } = new();
        public MemoryPkceStateStore Pkce { get; } = new();
        public List<Uri> BrowserUris { get; } = [];
        public Func<Uri, Task<bool>>? LaunchOverride { get; set; }
        public NativeClientCoordinator Coordinator { get; }
        public NativeAuthService Auth { get; }

        public Fixture(PendingPkceChallenge? persistedChallenge = null)
        {
            if (persistedChallenge is not null) Pkce.Save(persistedChallenge);
            var (api, proxy) = NativeApiProxy.Wrap(Api);
            Proxy = proxy;
            Coordinator = new NativeClientCoordinator(api, Store, new FakeVpnControlClient(), "1.0.0");
            Auth = new NativeAuthService(api, Coordinator, Store, Pkce, new Uri("https://vexguard.app"), uri =>
            {
                BrowserUris.Add(uri);
                return LaunchOverride?.Invoke(uri) ?? Task.FromResult(true);
            });
        }
    }

    private sealed class MemoryPkceStateStore : IPkceStateStore
    {
        public PendingPkceChallenge? Pending { get; private set; }
        public Exception? ClearError { get; set; }
        public Action? BeforeClear { get; set; }
        public PendingPkceChallenge? Load() => Pending;
        public void Save(PendingPkceChallenge pendingChallenge) => Pending = pendingChallenge;
        public void Clear()
        {
            BeforeClear?.Invoke();
            if (ClearError is not null) throw ClearError;
            Pending = null;
        }
    }

    private sealed class CountingClientStateStore : IClientStateStore
    {
        public NativeClientState? State { get; private set; }
        public int SaveCount { get; private set; }
        public ClientStateAccessKind GetAccessState() => State is null
            ? ClientStateAccessKind.Missing : ClientStateAccessKind.Available;
        public string GetOrCreateInstallationId() => "browser-installation-1";
        public NativeClientState? Load() => State;
        public NativeDeviceState? LoadDevice() => State is null ? null
            : new(State.InstallationId, State.DeviceId, State.LocationId, State.Identity);
        public void Save(NativeClientState state)
        {
            State = state;
            SaveCount++;
        }
        public void Clear() => State = null;
    }
}

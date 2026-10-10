using System.Net;
using Vex.Windows.App.Auth;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Session;

internal static class AuthenticatedSessionProvisioningTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await EveryProductionLoginSavesSessionWithoutProvisioningAsync();
        await UnpaidAccountStaysLoggedInAndRegistersAfterPaymentAsync();
        await RegistrationFailurePreservesLoginAndCanRetryAsync();
        await ForeignAccountCannotReuseDeviceKeyOrAuthorityAsync();
        await CanceledLoginCannotPersistLateAuthenticationAsync();
        await SupersededBrowserResponseCannotReplaceNewPasswordLoginAsync();
        await CanceledLazyRegistrationKeepsSessionAndRejectsLateDeviceAsync();
    }

    private static async Task EveryProductionLoginSavesSessionWithoutProvisioningAsync()
    {
        foreach (var mode in new[] { "password", "email", "browser" })
        {
            var fixture = new Fixture { Entitlement = FakeNativeClientApi.NoVpnEntitlement };
            if (mode == "password")
                await fixture.Auth.SignInWithPasswordAsync("user@example.com", "password", CancellationToken.None);
            else if (mode == "email")
            {
                await fixture.Auth.RequestEmailOtpAsync("user@example.com", CancellationToken.None);
                await fixture.Auth.ConfirmEmailOtpAsync("user@example.com", "123456", CancellationToken.None);
            }
            else
            {
                await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
                await fixture.Auth.HandleProtocolActivationAsync(Callback(fixture.Pkce.Pending!), CancellationToken.None);
            }
            Check(fixture.Auth.Error is null && !string.IsNullOrWhiteSpace(fixture.Auth.Notice),
                "An authenticated account must complete login even without a paid VPN entitlement: " + mode);
            AssertPending(fixture, fixture.Session.User.Id);
            var persisted = System.Text.Json.JsonSerializer.Deserialize<NativeClientState>(
                System.Text.Json.JsonSerializer.Serialize(fixture.Store.State));
            Check(persisted is { VpnProvisioningPending: true } && NativeClientStateValidation.IsValid(persisted),
                "The authenticated pending state must survive persistence and pass the actual protected-file state validator.");
            Check(fixture.VpnCalls.Count == 0 && fixture.ProfileDeviceIds.Count == 0 && fixture.Vpn.Authorization is null,
                "Password, OTP and browser login must not request billing/catalog, reserve a device slot, or issue a VPN profile.");
        }
    }

    private static async Task UnpaidAccountStaysLoggedInAndRegistersAfterPaymentAsync()
    {
        var fixture = new Fixture { Entitlement = FakeNativeClientApi.NoVpnEntitlement };
        await fixture.Auth.SignInWithPasswordAsync("user@example.com", "password", CancellationToken.None);
        var token = fixture.Store.State!.Session.AccessToken;
        await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "vpn_entitlement_required");
        AssertPending(fixture, fixture.Session.User.Id);
        Check(fixture.VpnCalls.SequenceEqual(["entitlement"]) && fixture.Store.State!.Session.AccessToken == token,
            "Unpaid Connect must stop at authoritative billing before catalog or registration and retain the logged-in account.");

        fixture.Entitlement = fixture.Api.Entitlement;
        fixture.VpnCalls.Clear();
        var response = await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(response.Success && fixture.Store.State is { VpnProvisioningPending: false } &&
            fixture.Store.State.DeviceId == "device-user-1" && fixture.RegistrationAttempts == 1 &&
            fixture.VpnCalls.IndexOf("entitlement") < fixture.VpnCalls.IndexOf("register") &&
            fixture.ProfileDeviceIds.SequenceEqual(["device-user-1"]) && fixture.Vpn.Authorization is not null,
            "A later paid Connect must check fresh billing, lazily register exactly once, then request and connect the new device profile.");
    }

    private static async Task RegistrationFailurePreservesLoginAndCanRetryAsync()
    {
        foreach (var failure in new[] { "quota", "offline", "catalog", "legacy" })
        {
            var fixture = new Fixture();
            fixture.RegisterRequest = (_, _) => failure == "quota"
                ? Task.FromException<VpnDevice>(new VexApiException(HttpStatusCode.Conflict, "vpn_device_limit_reached"))
                : Task.FromException<VpnDevice>(new HttpRequestException("Device registration offline"));
            if (failure == "catalog") fixture.Locations = [];
            if (failure == "legacy") fixture.Locations = [new("legacy-exit", "Legacy", "available", 2, Awg3Nodes: 0)];
            await fixture.Auth.SignInWithPasswordAsync("user@example.com", "password", CancellationToken.None);
            Check(fixture.Auth.Error is null && fixture.RegistrationAttempts == 0,
                "Full quota, registration downtime or unavailable VPN exits must not block account login.");
            var session = fixture.Store.State!.Session;
            if (failure == "quota")
                await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
                    error => error.Code == "vpn_device_limit_reached");
            else if (failure == "offline")
                await ExpectAsync<HttpRequestException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            else
                await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
                    error => error.Code == "vpn_location_unavailable");
            AssertPending(fixture, fixture.Session.User.Id);
            Check(fixture.Store.State!.Session == session && fixture.ProfileDeviceIds.Count == 0 && fixture.Vpn.Authorization is null,
                "Registration/catalog failure must leave the account available without a device or execution grant.");

            fixture.RegisterRequest = null;
            fixture.Locations = [AvailableLocation()];
            Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
                fixture.Store.State is { VpnProvisioningPending: false } && fixture.Store.State.Session == session &&
                fixture.RegistrationAttempts == (failure is "catalog" or "legacy" ? 1 : 2),
                "Recovering quota, registration or catalog must allow a subsequent Connect using the original authenticated account.");
        }
    }

    private static async Task ForeignAccountCannotReuseDeviceKeyOrAuthorityAsync()
    {
        var fixture = new Fixture();
        await fixture.Coordinator.SignInAndProvisionAsync("user@example.com", "password", CancellationToken.None);
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success, "Prior account fixture must have an execution grant.");
        var previous = fixture.Store.State!;
        var authorization = previous.CachedAuthorization!;
        var expires = DateTimeOffset.UtcNow.AddHours(1);
        fixture.Store.Save(previous with
        {
            WarmedProfile = new(previous.Session.User.Id, previous.DeviceId, previous.LocationId, previous.RoutingMode,
                previous.BypassRegion, previous.Identity.PublicKey, previous.Identity.KeyEpoch, 1, authorization, expires),
            CachedCandidateGrants = [new("candidate-old", "node-old", "198.51.100.1:443", previous.Session.User.Id,
                previous.DeviceId, previous.LocationId, previous.RoutingMode, previous.BypassRegion,
                previous.Identity.PublicKey, previous.Identity.KeyEpoch, 1, authorization, expires, expires)],
            CachedCandidatePolicyExpiresAt = expires,
        });
        fixture.Vpn.Authorization = null;
        fixture.Session = Session("user-2");
        fixture.VpnCalls.Clear();
        fixture.ProfileDeviceIds.Clear();
        await fixture.Auth.SignInWithPasswordAsync("other@example.com", "password", CancellationToken.None);
        AssertPending(fixture, "user-2");
        Check(fixture.Store.State!.Identity.PublicKey != previous.Identity.PublicKey &&
            fixture.Store.State.CachedEntitlement is null && fixture.Store.State.CachedEntitlementCheckedAt is null &&
            fixture.Store.State.CachedEntitlementValidUntil is null && fixture.VpnCalls.Count == 0,
            "A new user cannot inherit another user's owned device, WireGuard identity or cached paid authority.");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.Store.State!.DeviceId == "device-user-2" && fixture.ProfileDeviceIds.SequenceEqual(["device-user-2"]) &&
            fixture.Vpn.PrivateKey == fixture.Store.State.Identity.PrivateKey && fixture.Vpn.PrivateKey != previous.Identity.PrivateKey,
            "The new account must provision and execute its own device and key instead of the previous account's profile.");
    }

    private static async Task CanceledLoginCannotPersistLateAuthenticationAsync()
    {
        var fixture = new Fixture();
        var entered = Signal();
        var late = Result<VexAuthSession>();
        CancellationToken loginToken = default;
        fixture.LoginRequest = token => { loginToken = token; entered.TrySetResult(); return late.Task; };
        using var cancellation = new CancellationTokenSource();
        var login = fixture.Auth.SignInWithPasswordAsync("user@example.com", "password", cancellation.Token);
        await entered.Task.WaitAsync(Deadline);
        cancellation.Cancel();
        late.TrySetResult(fixture.Session);
        await CompleteCanceledAsync(login);
        Check(loginToken.IsCancellationRequested && fixture.Store.State is null && fixture.Store.SaveCount == 0 &&
            fixture.VpnCalls.Count == 0 && fixture.Vpn.Authorization is null,
            "A password server ignoring cancellation cannot persist its late session or begin VPN provisioning.");
    }

    private static async Task SupersededBrowserResponseCannotReplaceNewPasswordLoginAsync()
    {
        var fixture = new Fixture();
        var entered = Signal();
        var late = Result<VexAuthSession>();
        CancellationToken oldToken = default;
        fixture.ExchangeRequest = token => { oldToken = token; entered.TrySetResult(); return late.Task; };
        await fixture.Auth.StartBrowserAuthAsync(WebAuthMode.Login, CancellationToken.None);
        var oldCallback = fixture.Auth.HandleProtocolActivationAsync(Callback(fixture.Pkce.Pending!), CancellationToken.None);
        await entered.Task.WaitAsync(Deadline);
        fixture.Auth.CancelBrowserAuth();
        await oldCallback.WaitAsync(Deadline);
        fixture.Session = Session("user-2");
        await fixture.Auth.SignInWithPasswordAsync("other@example.com", "password", CancellationToken.None).WaitAsync(Deadline);
        var fresh = fixture.Store.State;
        var notice = fixture.Auth.Notice;
        late.TrySetResult(Session("user-1"));
        await late.Task;
        Check(oldToken.IsCancellationRequested && fixture.Store.State == fresh && fixture.Store.State?.Session.User.Id == "user-2" &&
            fixture.Store.SaveCount == 1 && fixture.Auth.Notice == notice && fixture.Auth.Error is null && fixture.VpnCalls.Count == 0,
            "A superseded browser exchange cannot overwrite a newer authenticated account, its status, or its pending provisioning state.");
    }

    private static async Task CanceledLazyRegistrationKeepsSessionAndRejectsLateDeviceAsync()
    {
        var fixture = new Fixture();
        await fixture.Auth.SignInWithPasswordAsync("user@example.com", "password", CancellationToken.None);
        var session = fixture.Store.State!.Session;
        var entered = Signal();
        var late = Result<VpnDevice>();
        CancellationToken registerToken = default;
        fixture.RegisterRequest = (_, token) => { registerToken = token; entered.TrySetResult(); return late.Task; };
        using var cancellation = new CancellationTokenSource();
        var connect = fixture.Coordinator.ConnectAsync(cancellation.Token);
        await entered.Task.WaitAsync(Deadline);
        cancellation.Cancel();
        late.TrySetResult(new("late-unwanted-device", "Windows", "active", fixture.Store.State!.Identity.PublicKey));
        await ExpectAsync<OperationCanceledException>(() => connect);
        AssertPending(fixture, fixture.Session.User.Id);
        Check(registerToken.IsCancellationRequested && fixture.Store.State!.Session == session &&
            fixture.ProfileDeviceIds.Count == 0 && fixture.Vpn.Authorization is null,
            "A device registration completing after Connect cancellation must not replace the pending authenticated session or issue a profile.");
        fixture.RegisterRequest = null;
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.RegistrationAttempts == 2 && fixture.Store.State!.DeviceId == "device-user-1" &&
            fixture.ProfileDeviceIds.SequenceEqual(["device-user-1"]),
            "Fresh Connect must register authoritatively rather than adopting a device returned after canceled intent.");
    }

    private static void AssertPending(Fixture fixture, string userId)
    {
        var state = fixture.Store.State;
        Check(state is { VpnProvisioningPending: true } && state.Session.User.Id == userId &&
            string.IsNullOrEmpty(state.DeviceId) && state.CachedAuthorization is null && state.CachedProfileVersion is null &&
            state.CachedCandidateGrants is null && state.CachedCandidatePolicyExpiresAt is null && state.WarmedProfile is null,
            "Authenticated pending state needs the valid account, no invented device ID, and no VPN execution grants.");
    }

    private static async Task CompleteCanceledAsync(Task operation)
    {
        try { await operation.WaitAsync(Deadline); }
        catch (OperationCanceledException) { }
    }

    private static async Task ExpectAsync<TException>(Func<Task> action, Func<TException, bool>? match = null)
        where TException : Exception
    {
        try { await action().WaitAsync(Deadline); }
        catch (TException error) when (match is null || match(error)) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + " from the authenticated provisioning attempt.");
    }

    private static VexAuthSession Session(string userId) => new(new(userId, userId + "@example.com", "active"),
        "access-" + userId, DateTimeOffset.UtcNow.AddDays(30));
    private static VpnLocation AvailableLocation() => new("fi-1", "Helsinki", "available", 1, Awg3Nodes: 1);
    private static Uri Callback(PendingPkceChallenge challenge) =>
        new("vexguard://auth/callback?code=browser-code&state=" + Uri.EscapeDataString(challenge.State));
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static TaskCompletionSource<T> Result<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture
    {
        public FakeNativeClientApi Api { get; } = new();
        public OwnedStateStore Store { get; } = new();
        public MemoryPkceStateStore Pkce { get; } = new();
        public FakeVpnControlClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; }
        public NativeAuthService Auth { get; }
        public VexAuthSession Session { get; set; } = AuthenticatedSessionProvisioningTests.Session("user-1");
        public VexEntitlement Entitlement { get; set; }
        public IReadOnlyList<VpnLocation> Locations { get; set; } = [AvailableLocation()];
        public Func<CancellationToken, Task<VexAuthSession>>? LoginRequest { get; set; }
        public Func<CancellationToken, Task<VexAuthSession>>? ExchangeRequest { get; set; }
        public Func<string, CancellationToken, Task<VpnDevice>>? RegisterRequest { get; set; }
        public List<string> VpnCalls { get; } = [];
        public List<string> ProfileDeviceIds { get; } = [];
        public int RegistrationAttempts { get; private set; }

        public Fixture()
        {
            Entitlement = Api.Entitlement;
            var (api, proxy) = NativeApiProxy.Wrap(Api);
            proxy.Overrides[nameof(INativeClientApi.LoginAsync)] = args =>
                LoginRequest?.Invoke((CancellationToken)args[^1]!) ?? Task.FromResult(Session);
            proxy.Overrides[nameof(INativeClientApi.ConfirmEmailOtpAsync)] = _ => Task.FromResult(Session);
            proxy.Overrides[nameof(INativeClientApi.ExchangeAppAuthCodeAsync)] = args =>
                ExchangeRequest?.Invoke((CancellationToken)args[^1]!) ?? Task.FromResult(Session);
            proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
            {
                VpnCalls.Add("entitlement");
                return Task.FromResult(Entitlement);
            };
            proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ =>
            {
                VpnCalls.Add("locations");
                return Task.FromResult(Locations);
            };
            proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = args =>
            {
                VpnCalls.Add("register");
                RegistrationAttempts++;
                var publicKey = (string)args[2]!;
                return RegisterRequest?.Invoke(publicKey, (CancellationToken)args[^1]!) ??
                    Task.FromResult(new VpnDevice("device-" + Session.User.Id, "Windows", "active", publicKey));
            };
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
            {
                VpnCalls.Add("profile");
                ProfileDeviceIds.Add((string)args[1]!);
                return proxy.CallUnderlying(nameof(INativeClientApi.GetManagedVpnProfileAsync), args);
            };
            Coordinator = new(api, Store, Vpn, "1.0.0");
            Auth = new(api, Coordinator, Store, Pkce, new("https://vexguard.app"), _ => Task.FromResult(true));
        }
    }

    private sealed class OwnedStateStore : IClientStateStore
    {
        public NativeClientState? State { get; private set; }
        public int SaveCount { get; private set; }
        public ClientStateAccessKind GetAccessState() => State is null ? ClientStateAccessKind.Missing : ClientStateAccessKind.Available;
        public string GetOrCreateInstallationId() => "session-only-installation";
        public NativeClientState? Load() => State;
        public NativeDeviceState? LoadDevice() => State is null ? null :
            new(State.InstallationId, State.DeviceId, State.LocationId, State.Identity, UserId: State.Session.User.Id);
        public void Save(NativeClientState state) { State = state; SaveCount++; }
        public void Clear() => State = null;
    }

    private sealed class MemoryPkceStateStore : IPkceStateStore
    {
        public PendingPkceChallenge? Pending { get; private set; }
        public PendingPkceChallenge? Load() => Pending;
        public void Save(PendingPkceChallenge challenge) => Pending = challenge;
        public void Clear() => Pending = null;
    }
}

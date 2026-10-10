using System.Net;
using System.Reflection;
using System.Runtime.ExceptionServices;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class ClientRecoveryParityTests
{
    public static void Run()
    {
        CachedPaidAccessCannotBypassRevocation();
        OfflineReconnectUsesBoundedPaidCache();
        ExpiredAccessCannotReconnectOffline();
        UnauthorizedProfileRefreshesAndRetriesOnce();
        RepeatedUnauthorizedExpiresSession();
        ManualPinNeverFailsOver();
        AutomaticRecoveryHasThreeAttemptBudget();
        AdmissionFailureNeverRetries();
        PolicyTransportFailureDoesNotBlockRecovery();
        FailedServerSwitchRestoresPreviousGrant();
        GoogleAuthUsesTheSamePkceContract();
        WindowsResilienceUsesBackendContract();
        MalformedAuthFailsWithoutCrashing();
    }

    private static readonly DateTimeOffset InitialTime = new(2026, 10, 10, 12, 0, 0, TimeSpan.Zero);

    private static (FakeNativeClientApi Api, MemoryClientStateStore Store, NativeClientCoordinator Coordinator)
        Fixture(IVpnControlClient vpn, Func<DateTimeOffset>? now = null, INativeClientApi? suppliedApi = null)
    {
        var api = new FakeNativeClientApi
        {
            Locations = [new("fi-1", "Helsinki", "available", 1), new("de-1", "Frankfurt", "available", 1)],
        };
        var store = new MemoryClientStateStore();
        var coordinator = new NativeClientCoordinator(suppliedApi ?? api, store, vpn, "1.0.0", now ?? (() => InitialTime));
        coordinator.SignInAndProvisionAsync("user@example.com", "password", CancellationToken.None).GetAwaiter().GetResult();
        return (api, store, coordinator);
    }

    private static void CachedPaidAccessCannotBypassRevocation()
    {
        var vpn = new SequenceVpnClient();
        var fixture = Fixture(vpn);
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        fixture.Coordinator.InvalidateCachedEntitlementAsync(CancellationToken.None).GetAwaiter().GetResult();
        var inactive = new FakeNativeClientApi { Entitlement = FakeNativeClientApi.NoVpnEntitlement };
        var coordinator = new NativeClientCoordinator(inactive, fixture.Store, vpn, "1.0.0", () => InitialTime);
        ExpectFlow("vpn_entitlement_required", () => coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult());
        Check(vpn.ConnectCount == 1, "Revoked access reused the cached signed grant.");
    }

    private static void OfflineReconnectUsesBoundedPaidCache()
    {
        var now = InitialTime;
        var vpn = new SequenceVpnClient();
        var fixture = Fixture(vpn, () => now);
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        now = now.AddMinutes(10);
        var (api, proxy) = NativeApiProxy.Wrap(fixture.Api);
        proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
            throw new HttpRequestException("offline");
        var coordinator = new NativeClientCoordinator(api, fixture.Store, vpn, "1.0.0", () => now);
        Check(coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult().Success,
            "A valid bounded paid cache could not reconnect offline.");
        Check(fixture.Api.ProfileCalls == 1, "Offline reconnect fetched a new profile.");
    }

    private static void ExpiredAccessCannotReconnectOffline()
    {
        var now = InitialTime;
        var vpn = new SequenceVpnClient();
        var fixture = Fixture(vpn, () => now);
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        now = now.AddHours(25);
        var (api, proxy) = NativeApiProxy.Wrap(fixture.Api);
        proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
            throw new HttpRequestException("offline");
        var coordinator = new NativeClientCoordinator(api, fixture.Store, vpn, "1.0.0", () => now);
        try { coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult(); }
        catch (HttpRequestException) { Check(vpn.ConnectCount == 1, "Expired paid cache reached the service."); return; }
        throw new InvalidOperationException("Expired paid cache was accepted offline.");
    }

    private static void UnauthorizedProfileRefreshesAndRetriesOnce()
    {
        var underlying = new FakeNativeClientApi
        {
            RefreshThrowsIfCalled = false,
            RefreshResult = new(new("user-1", "user@example.com", "active"), "refreshed-token", InitialTime.AddDays(1)),
        };
        var (api, proxy) = NativeApiProxy.Wrap(underlying);
        var attempts = 0;
        proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
        {
            attempts++;
            if (attempts == 1) { throw new VexApiException(HttpStatusCode.Unauthorized, "auth_required"); }
            return proxy.CallUnderlying(nameof(INativeClientApi.GetManagedVpnProfileAsync), args);
        };
        var fixture = Fixture(new SequenceVpnClient(), suppliedApi: api);
        Check(fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult().Success,
            "401 profile retry did not connect.");
        Check(attempts == 2 && underlying.RefreshCalls == 1 && fixture.Store.State?.Session.AccessToken == "refreshed-token",
            "401 refresh was not single-shot or was not persisted.");
    }

    private static void RepeatedUnauthorizedExpiresSession()
    {
        var underlying = new FakeNativeClientApi
        {
            RefreshThrowsIfCalled = false,
            RefreshResult = new(new("user-1", "user@example.com", "active"), "refreshed-token", InitialTime.AddDays(1)),
        };
        var (api, proxy) = NativeApiProxy.Wrap(underlying);
        proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = _ =>
            throw new VexApiException(HttpStatusCode.Unauthorized, "auth_required");
        var fixture = Fixture(new SequenceVpnClient(), suppliedApi: api);
        ExpectFlow("sign_in_required", () => fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult());
        Check(fixture.Store.State is null && underlying.RefreshCalls == 1,
            "Repeated 401 did not expire the stored session.");
    }

    private static void ManualPinNeverFailsOver()
    {
        var vpn = new SequenceVpnClient("tunnel_no_handshake", "tunnel_no_handshake");
        var fixture = Fixture(vpn);
        var response = fixture.Coordinator.ConnectWithRecoveryAsync("fi-1", "full", false, false,
            CancellationToken.None).GetAwaiter().GetResult();
        Check(!response.Success && vpn.ConnectCount == 2 && fixture.Api.ProfileLocationIds.All(id => id == "fi-1"),
            "Manual exit was changed during recovery.");
        Check(vpn.AntiLeakValues.All(enabled => !enabled), "Recovery ignored the anti-leak preference.");
    }

    private static void AutomaticRecoveryHasThreeAttemptBudget()
    {
        var vpn = new SequenceVpnClient("tunnel_no_handshake", "tunnel_no_handshake", null);
        var fixture = Fixture(vpn);
        var response = fixture.Coordinator.ConnectWithRecoveryAsync("fi-1", "full", true, true,
            CancellationToken.None).GetAwaiter().GetResult();
        Check(response.Success && vpn.ConnectCount == 3 &&
            fixture.Api.ProfileLocationIds.SequenceEqual(["fi-1", "fi-1", "de-1"]),
            "Automatic recovery did not keep same-exit-first and bounded alternate-exit behavior.");
    }

    private static void AdmissionFailureNeverRetries()
    {
        var vpn = new SequenceVpnClient("profile_signature_invalid");
        var fixture = Fixture(vpn);
        var response = fixture.Coordinator.ConnectWithRecoveryAsync("fi-1", "full", true, true,
            CancellationToken.None).GetAwaiter().GetResult();
        Check(!response.Success && vpn.ConnectCount == 1, "Invalid signed admission triggered an alternate route.");
    }

    private static void PolicyTransportFailureDoesNotBlockRecovery()
    {
        var (api, proxy) = NativeApiProxy.Wrap(new FakeNativeClientApi());
        proxy.Overrides[nameof(INativeClientApi.GetResiliencePolicyAsync)] = _ =>
            throw new HttpRequestException("policy offline");
        var vpn = new SequenceVpnClient("tunnel_no_handshake", null);
        var fixture = Fixture(vpn, suppliedApi: api);
        Check(fixture.Coordinator.ConnectWithRecoveryAsync("fi-1", "full", true, false,
            CancellationToken.None).GetAwaiter().GetResult().Success && vpn.ConnectCount == 2,
            "Optional resilience transport failure blocked the fresh signed profile retry.");
    }

    private static void FailedServerSwitchRestoresPreviousGrant()
    {
        var vpn = new SequenceVpnClient(null, "tunnel_no_handshake", "tunnel_no_handshake", null);
        var fixture = Fixture(vpn);
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        ExpectFlow("tunnel_no_handshake", () => fixture.Coordinator.SelectLocationAsync("de-1", true,
            CancellationToken.None, false).GetAwaiter().GetResult());
        Check(fixture.Store.State?.LocationId == "fi-1" && vpn.ConnectCount == 4 && vpn.DisconnectCount == 0,
            "Failed switch did not restore the prior signed grant without premature disconnect.");
    }

    private static void GoogleAuthUsesTheSamePkceContract()
    {
        var request = PkceAuthFlow.CreateRequest(new("https://vexguard.app"), "device-1", "Windows", "windows",
            WebAuthMode.Login, size => new string('a', size), WebAuthProvider.Google);
        Check(request.Url.Query.Contains("provider=google", StringComparison.Ordinal) &&
            request.Url.Query.Contains("code_challenge=", StringComparison.Ordinal), "Google auth lost provider or PKCE.");
    }

    private static void WindowsResilienceUsesBackendContract()
    {
        var handler = new RoutingHttpHandler(request =>
        {
            Check(request.RequestUri?.AbsolutePath == "/v1/resilience/policy" &&
                request.Headers.Authorization?.Parameter == "token", "Wrong resilience API path or authorization.");
            return new(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"policy_version\":\"v1\",\"generated_at\":\"2026-10-10T12:00:00Z\",\"expires_at\":\"2026-10-10T13:00:00Z\",\"signature\":{\"status\":\"signed\"},\"probe\":{\"connect_timeout_ms\":8000,\"max_candidates\":3,\"checks\":[]},\"candidates\":[]}"),
            };
        });
        var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://vexguard.app") });
        Check(api.GetResiliencePolicyAsync("token", CancellationToken.None).GetAwaiter().GetResult()?.Probe.MaxCandidates == 3,
            "Resilience policy contract was not decoded.");
    }

    private static void MalformedAuthFailsWithoutCrashing()
    {
        var handler = new RecordingHttpHandler("{\"user\":{\"id\":\"user-1\",\"email\":\"user@example.com\",\"status\":\"active\"}}");
        var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://vexguard.app") });
        try { api.LoginAsync("user@example.com", "password", CancellationToken.None).GetAwaiter().GetResult(); }
        catch (VexApiException error) when (error.Code == "api_response_invalid") { return; }
        throw new InvalidOperationException("Malformed auth did not fail with a safe API error.");
    }

    private static void ExpectFlow(string code, Action action)
    {
        try { action(); }
        catch (NativeClientFlowException error) when (error.Code == code) { return; }
        throw new InvalidOperationException("Expected flow error " + code);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    private sealed class SequenceVpnClient(params string?[] outcomes) : IVpnControlClient
    {
        private VpnConnectionSnapshot _snapshot = VpnConnectionSnapshot.Disconnected();
        public int ConnectCount { get; private set; }
        public int DisconnectCount { get; private set; }
        public List<bool> AntiLeakValues { get; } = [];
        public Task<VpnServiceResponse> GetStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new VpnServiceResponse("status", true, _snapshot, null));
        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization,
            string privateKey, CancellationToken cancellationToken) => ConnectAsync(authorization, privateKey, true, cancellationToken);
        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization,
            string privateKey, bool antiLeakEnabled, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AntiLeakValues.Add(antiLeakEnabled);
            var error = ConnectCount < outcomes.Length ? outcomes[ConnectCount] : null;
            ConnectCount++;
            _snapshot = new(error is null ? VpnConnectionPhase.Connected : VpnConnectionPhase.Error,
                "fi-1", ConnectCount, error);
            return Task.FromResult(new VpnServiceResponse("connect-" + ConnectCount, error is null, _snapshot, error));
        }
        public Task<VpnServiceResponse> DisconnectAsync(CancellationToken cancellationToken)
        {
            DisconnectCount++;
            _snapshot = VpnConnectionSnapshot.Disconnected();
            return GetStatusAsync(cancellationToken);
        }
    }
}

public class NativeApiProxy : DispatchProxy
{
    private INativeClientApi _underlying = null!;
    public Dictionary<string, Func<object?[], object?>> Overrides { get; } = [];

    public static (INativeClientApi Api, NativeApiProxy Proxy) Wrap(INativeClientApi underlying)
    {
        var api = Create<INativeClientApi, NativeApiProxy>();
        var proxy = (NativeApiProxy)api;
        proxy._underlying = underlying;
        return (api, proxy);
    }

    public object? CallUnderlying(string method, object?[] args)
    {
        try { return typeof(INativeClientApi).GetMethod(method)!.Invoke(_underlying, args); }
        catch (TargetInvocationException error) when (error.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(error.InnerException).Throw();
            throw;
        }
    }

    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        var method = targetMethod!.Name;
        return Overrides.TryGetValue(method, out var callback)
            ? callback(args ?? []) : CallUnderlying(method, args ?? []);
    }
}

using System.Net;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;

internal static class ClientAccountSnapshotTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 10, 12, 0, 0, TimeSpan.Zero);
    private static readonly VpnDevice Device = new("device-1", "My Windows", "active", null);
    private static readonly VpnDeviceUsage Usage = new("device-1", "connected", true, 5, 123, 456, 579);
    private static readonly BillingPayment Payment = new("payment-1", null, null, "pro_monthly", "platega", 49900,
        "RUB", "card", "paid", null, null, null, null, "2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z");

    public static void Run()
    {
        OptionalFailureDoesNotHideSubscription();
        FirstLoadPlansHttpFailureKeepsAuthoritativeEntitlement();
        LastSuccessfulSectionsRemainClearlyCached();
        OptionalUnauthorizedRefreshesAndRetries();
        RepeatedUnauthorizedExpiresSessionEvenWithPlansFailure();
        RequiredFailuresRemainAuthoritative();
        FreshRevocationSurvivesPlansFailure();
        MalformedOptionalSectionsRemainUnavailable();
        AccountIdentityIsVerifiedBeforeCommit();
        CallerCancellationDoesNotCommitLateData();
        OptionalRequestsHaveAnIndependentDeadline();
    }

    private static (FakeNativeClientApi Api, NativeApiProxy Proxy, MemoryClientStateStore Store, NativeClientCoordinator Coordinator) Fixture()
    {
        var underlying = new FakeNativeClientApi
        {
            RefreshThrowsIfCalled = false,
            RefreshResult = new(new("user-1", "user@example.com", "active"), "fresh-token", Now.AddDays(1)),
        };
        var (api, proxy) = NativeApiProxy.Wrap(underlying);
        var store = new MemoryClientStateStore();
        var coordinator = new NativeClientCoordinator(api, store, new FakeVpnControlClient(), "1.0.0", () => Now);
        coordinator.SignInAndProvisionAsync("user@example.com", "password", default).GetAwaiter().GetResult();
        return (underlying, proxy, store, coordinator);
    }

    private static void OptionalFailureDoesNotHideSubscription()
    {
        foreach (var section in new[] { nameof(INativeClientApi.GetBillingPlansAsync), nameof(INativeClientApi.GetDevicesAsync), nameof(INativeClientApi.GetDeviceUsageAsync), nameof(INativeClientApi.GetBillingPaymentsAsync) })
        {
            var fixture = Fixture();
            fixture.Proxy.Overrides[section] = _ => throw new VexApiException(HttpStatusCode.ServiceUnavailable, "section_unavailable");
            var account = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
            Check(account.Email == "user@example.com" && account.Entitlement.HasPaidAccess && account.BillingSummary.CurrentPlan?.Id == "pro_monthly",
                "An optional account failure hid current profile/subscription data.");
            var status = section == nameof(INativeClientApi.GetBillingPlansAsync) ? account.BillingSummaryStatus : section == nameof(INativeClientApi.GetDevicesAsync) ? account.DevicesStatus
                : section == nameof(INativeClientApi.GetDeviceUsageAsync) ? account.DeviceUsageStatus : account.PaymentsStatus;
            Check(status.Availability == NativeAccountSectionAvailability.Unavailable && status.ErrorCode == "section_unavailable",
                "Optional failure became a fake successful empty section.");
            Check(fixture.Store.State?.CachedEntitlement == account.Entitlement, "Fresh entitlement was not admitted after optional failure.");
        }
    }

    private static void FirstLoadPlansHttpFailureKeepsAuthoritativeEntitlement()
    {
        var fixture = Fixture();
        var handler = new RoutingHttpHandler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            var body = path switch
            {
                "/v1/auth/me" => System.Text.Json.JsonSerializer.Serialize(fixture.Store.State!.Session.User),
                "/v1/billing/entitlement" => System.Text.Json.JsonSerializer.Serialize(fixture.Api.Entitlement),
                "/v1/devices/usage" => "{\"usage\":[]}",
                _ => "[]",
            };
            return new HttpResponseMessage(path == "/v1/billing/plans" ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK)
            {
                Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json"),
            };
        });
        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://api.example.test") };
        var coordinator = new NativeClientCoordinator(new VexApiClient(http), fixture.Store, new FakeVpnControlClient(), "1.0.0", () => Now);
        var snapshot = coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(snapshot.Entitlement.HasPaidAccess && snapshot.BillingSummary.EntitlementStatus == "active" &&
            snapshot.BillingSummaryStatus.Availability == NativeAccountSectionAvailability.Unavailable,
            "First-load public plan 5xx hid the authoritative subscription or became fresh empty plans.");
        Check(handler.Requests.Count(request => request.RequestUri!.AbsolutePath == "/v1/billing/entitlement") == 1,
            "Account summary fetched authoritative entitlement more than once.");
    }

    private static void LastSuccessfulSectionsRemainClearlyCached()
    {
        var fixture = Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = _ => Task.FromResult<IReadOnlyList<VpnDevice>>([Device]);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetDeviceUsageAsync)] = _ => Task.FromResult<IReadOnlyList<VpnDeviceUsage>>([Usage]);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPaymentsAsync)] = _ => Task.FromResult<IReadOnlyList<BillingPayment>>([Payment]);
        fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        foreach (var section in new[] { nameof(INativeClientApi.GetBillingPlansAsync), nameof(INativeClientApi.GetDevicesAsync), nameof(INativeClientApi.GetDeviceUsageAsync), nameof(INativeClientApi.GetBillingPaymentsAsync) })
            fixture.Proxy.Overrides[section] = _ => throw new HttpRequestException("Offline");
        var cached = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(cached.Devices.Single() == Device && cached.DeviceUsage.Single() == Usage && cached.Payments.Single() == Payment,
            "Refresh failure discarded previously successful optional data.");
        Check(cached.BillingPlans.Count == 1 && new[] { cached.BillingSummaryStatus, cached.DevicesStatus, cached.DeviceUsageStatus, cached.PaymentsStatus }.All(status => status.Availability == NativeAccountSectionAvailability.Cached),
            "Cached sections were presented as fresh.");
        var state = fixture.Store.State!;
        fixture.Store.SetExternalSnapshot(state with { Session = state.Session with { User = new("user-2", "other@example.com", "active") } });
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetCurrentUserAsync)] = _ => Task.FromResult(new VexUser("user-2", "other@example.com", "active"));
        var changed = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(changed.Devices.Count == 0 && changed.DeviceUsage.Count == 0 && changed.Payments.Count == 0 &&
            changed.BillingPlans.Count == 0 && new[] { changed.BillingSummaryStatus, changed.DevicesStatus, changed.DeviceUsageStatus, changed.PaymentsStatus }.All(status => !status.HasData),
            "Another user received a previous account's optional cache.");
    }

    private static void OptionalUnauthorizedRefreshesAndRetries()
    {
        var fixture = Fixture();
        var calls = 0;
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPaymentsAsync)] = args =>
        {
            calls++;
            if (calls == 1) throw new VexApiException(HttpStatusCode.Unauthorized, "session_expired");
            Check((string)args[0]! == "fresh-token", "Optional retry reused rejected credentials.");
            return Task.FromResult<IReadOnlyList<BillingPayment>>([Payment]);
        };
        var account = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(calls == 2 && fixture.Api.RefreshCalls == 1 && account.PaymentsStatus.IsCurrent && account.Payments.Single() == Payment,
            "Optional 401 did not use the single authoritative session retry.");
    }

    private static void RepeatedUnauthorizedExpiresSessionEvenWithPlansFailure()
    {
        var fixture = Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPlansAsync)] = _ => Task.FromException<IReadOnlyList<BillingPlan>>(new HttpRequestException("Plans offline"));
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPaymentsAsync)] = _ => throw new VexApiException(HttpStatusCode.Unauthorized, "session_expired");
        try
        {
            fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
            throw new InvalidOperationException("Repeated account authorization rejection was downgraded to an optional failure.");
        }
        catch (NativeClientFlowException error) when (error.Code == "sign_in_required") { }
        Check(fixture.Store.State is null && fixture.Api.RefreshCalls == 1, "Repeated 401 did not expire the session after one retry.");
    }

    private static void RequiredFailuresRemainAuthoritative()
    {
        foreach (var section in new[] { nameof(INativeClientApi.GetBillingEntitlementAsync), nameof(INativeClientApi.GetCurrentUserAsync) })
        {
            var fixture = Fixture();
            fixture.Proxy.Overrides[section] = _ => throw new VexApiException(HttpStatusCode.ServiceUnavailable, "required_unavailable");
            try
            {
                fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
                throw new InvalidOperationException("Required account failure became a successful snapshot.");
            }
            catch (VexApiException error) when (error.Code == "required_unavailable") { }
            Check(fixture.Store.State is not null, "Transient required-section error revoked the session.");
        }
    }

    private static void FreshRevocationSurvivesPlansFailure()
    {
        var fixture = Fixture();
        fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPlansAsync)] = _ => Task.FromException<IReadOnlyList<BillingPlan>>(new HttpRequestException("Plans offline"));
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ => Task.FromResult(FakeNativeClientApi.NoVpnEntitlement);
        var snapshot = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(fixture.Store.State?.CachedEntitlement?.HasPaidAccess == false && !snapshot.Entitlement.HasPaidAccess &&
            snapshot.BillingSummary.EntitlementStatus == "inactive" && !snapshot.BillingSummaryStatus.IsCurrent,
            "An unrelated plans failure discarded an authoritative paid-access revocation.");
    }

    private static void CallerCancellationDoesNotCommitLateData()
    {
        foreach (var required in new[] { false, true })
        {
            var fixture = Fixture();
            var original = fixture.Store.State;
            using var cancellation = new CancellationTokenSource();
            var method = required ? nameof(INativeClientApi.GetCurrentUserAsync) : nameof(INativeClientApi.GetDeviceUsageAsync);
            fixture.Proxy.Overrides[method] = _ =>
            {
                cancellation.Cancel();
                return required ? new TaskCompletionSource<VexUser>().Task : (object)new TaskCompletionSource<IReadOnlyList<VpnDeviceUsage>>().Task;
            };
            try
            {
                fixture.Coordinator.GetAccountSnapshotAsync(cancellation.Token).WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
                throw new InvalidOperationException("Cancelled account load committed late or unavailable data.");
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            Check(ReferenceEquals(original, fixture.Store.State), "Cancelled snapshot altered the protected account state.");
            fixture.Proxy.Overrides.Remove(method);
            Check(fixture.Coordinator.GetAccountSnapshotAsync(default).WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult().UserId == "user-1",
                "An API that ignored cancellation kept the coordinator gate locked.");
        }
    }

    private static void AccountIdentityIsVerifiedBeforeCommit()
    {
        var fixture = Fixture();
        var original = fixture.Store.State;
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetCurrentUserAsync)] = _ => Task.FromResult(new VexUser("other-user", "user@example.com", "active"));
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPlansAsync)] = _ => throw new HttpRequestException("Plans offline");
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ => Task.FromResult(FakeNativeClientApi.NoVpnEntitlement);
        try
        {
            fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
            throw new InvalidOperationException("Mismatched account identity was admitted.");
        }
        catch (VexApiException error) when (error.Code == "api_response_invalid") { }
        Check(ReferenceEquals(original, fixture.Store.State), "Identity mismatch committed entitlement for an invalid account scope.");
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetCurrentUserAsync)] = _ => Task.FromResult(new VexUser("user-1", "renamed@example.com", "active"));
        var snapshot = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(snapshot.UserId == "user-1" && snapshot.Email == "renamed@example.com" && fixture.Store.State?.Session.User.Email == snapshot.Email,
            "Same-user email changes discarded the current account identity.");
    }

    private static void MalformedOptionalSectionsRemainUnavailable()
    {
        var fixture = Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPlansAsync)] = _ => Task.FromResult<IReadOnlyList<BillingPlan>>([null!]);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = _ => Task.FromResult<IReadOnlyList<VpnDevice>>([Device with { Status = null! }]);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetDeviceUsageAsync)] = _ => Task.FromResult<IReadOnlyList<VpnDeviceUsage>>([null!]);
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPaymentsAsync)] = _ => Task.FromResult<IReadOnlyList<BillingPayment>>([Payment with { Status = null! }]);
        var snapshot = fixture.Coordinator.GetAccountSnapshotAsync(default).GetAwaiter().GetResult();
        Check(snapshot.Entitlement.HasPaidAccess &&
            new[] { snapshot.BillingSummaryStatus, snapshot.DevicesStatus, snapshot.DeviceUsageStatus, snapshot.PaymentsStatus }
                .All(status => !status.HasData && status.ErrorCode == "api_response_invalid"),
            "Malformed optional items reached account rendering as current data.");
    }

    private static void OptionalRequestsHaveAnIndependentDeadline()
    {
        var fixture = Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetBillingPaymentsAsync)] = _ => new TaskCompletionSource<IReadOnlyList<BillingPayment>>().Task;
        var account = fixture.Coordinator.GetAccountSnapshotAsync(default).WaitAsync(TimeSpan.FromSeconds(12)).GetAwaiter().GetResult();
        Check(account.Entitlement.HasPaidAccess && account.PaymentsStatus.Availability == NativeAccountSectionAvailability.Unavailable &&
            account.PaymentsStatus.ErrorCode == "request_timeout", "An optional stalled request hid the subscription beyond its deadline.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

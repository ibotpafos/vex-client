using System.Net;
using Vex.Windows.Client.Api;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    private NativeAccountSnapshot? _cachedAccountSnapshot;
    private string? _cachedAccountUserId;

    private async Task<NativeAccountSnapshot> LoadAccountSnapshotCoreAsync(
        NativeClientState state, CancellationToken cancellationToken)
    {
        var cached = _cachedAccountUserId == state.Session.User.Id ? _cachedAccountSnapshot : null;
        var entitlementTask = _api.GetBillingEntitlementAsync(state.Session.AccessToken, cancellationToken);
        var userTask = _api.GetCurrentUserAsync(state.Session.AccessToken, cancellationToken);
        var plansTask = LoadOptionalAccountSectionAsync(_api.GetBillingPlansAsync,
            cached?.BillingSummaryStatus.HasData == true ? cached.BillingPlans : null, cancellationToken,
            plan => plan is not null && !string.IsNullOrWhiteSpace(plan.Id) && plan.Status is not null && plan.Tier is not null && plan.Interval is not null);
        var devicesTask = LoadOptionalAccountSectionAsync(
            token => _api.GetDevicesAsync(state.Session.AccessToken, token),
            cached?.DevicesStatus.HasData == true ? cached.Devices : null, cancellationToken,
            device => device is not null && !string.IsNullOrWhiteSpace(device.Id) && !string.IsNullOrWhiteSpace(device.Name) && device.Status is not null);
        var usageTask = LoadOptionalAccountSectionAsync(
            token => _api.GetDeviceUsageAsync(state.Session.AccessToken, token),
            cached?.DeviceUsageStatus.HasData == true ? cached.DeviceUsage : null, cancellationToken,
            usage => usage is not null && !string.IsNullOrWhiteSpace(usage.DeviceId));
        var paymentsTask = LoadOptionalAccountSectionAsync(
            token => _api.GetBillingPaymentsAsync(state.Session.AccessToken, 24, token),
            cached?.PaymentsStatus.HasData == true ? cached.Payments : null, cancellationToken,
            payment => payment is not null && !string.IsNullOrWhiteSpace(payment.Id) && payment.Status is not null && payment.Currency is not null);
        Task[] tasks = [entitlementTask, userTask, plansTask, devicesTask, usageTask, paymentsTask];
        try { await Task.WhenAll(tasks).WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch
        {
            cancellationToken.ThrowIfCancellationRequested();
            // A section's 401 is authoritative even if another request failed first.
            var unauthorized = tasks.SelectMany(task => task.Exception?.Flatten().InnerExceptions.AsEnumerable() ?? Enumerable.Empty<Exception>())
                .OfType<VexApiException>().FirstOrDefault(error => error.StatusCode == HttpStatusCode.Unauthorized);
            if (unauthorized is not null) throw unauthorized;
            if (userTask.IsCompletedSuccessfully && userTask.Result.Id != state.Session.User.Id)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            if (entitlementTask.IsCompletedSuccessfully)
                _stateStore.Save(CacheEntitlement(state, entitlementTask.Result));
            throw;
        }
        cancellationToken.ThrowIfCancellationRequested();
        var user = await userTask.ConfigureAwait(false);
        if (user.Id != state.Session.User.Id)
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        var entitlement = await entitlementTask.ConfigureAwait(false);
        var plans = await plansTask.ConfigureAwait(false);
        var devices = await devicesTask.ConfigureAwait(false);
        var usage = await usageTask.ConfigureAwait(false);
        var payments = await paymentsTask.ConfigureAwait(false);
        _stateStore.Save(CacheEntitlement(state with { Session = state.Session with { User = user } }, entitlement));
        var snapshot = new NativeAccountSnapshot(user.Email, state.LocationId, entitlement,
            BillingSummaryBuilder.Build(plans.Data, entitlement), devices.Data, usage.Data, payments.Data)
        {
            UserId = user.Id,
            BillingPlans = plans.Data, BillingSummaryStatus = plans.Status,
            DevicesStatus = devices.Status, DeviceUsageStatus = usage.Status, PaymentsStatus = payments.Status,
        };
        _cachedAccountUserId = user.Id;
        return _cachedAccountSnapshot = snapshot;
    }

    private static async Task<AccountSectionResult<T>> LoadOptionalAccountSectionAsync<T>(
        Func<CancellationToken, Task<IReadOnlyList<T>>> fetch, IReadOnlyList<T>? cached,
        CancellationToken cancellationToken, Func<T, bool> isValid)
    {
        using var request = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        request.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            var data = await fetch(request.Token).WaitAsync(request.Token).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (data is null || data.Any(item => !isValid(item)))
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            return new(data, NativeAccountSectionStatus.Current);
        }
        catch (Exception error) when (
            error is HttpRequestException or IOException ||
            error is VexApiException apiError && apiError.StatusCode != HttpStatusCode.Unauthorized ||
            error is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new(cached ?? [], new(cached is null
                ? NativeAccountSectionAvailability.Unavailable : NativeAccountSectionAvailability.Cached,
                error is VexApiException api ? api.Code : error is OperationCanceledException ? "request_timeout" : "request_failed"));
        }
    }

    private sealed record AccountSectionResult<T>(IReadOnlyList<T> Data, NativeAccountSectionStatus Status);
}

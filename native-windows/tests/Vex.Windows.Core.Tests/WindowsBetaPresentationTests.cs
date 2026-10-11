using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;

internal static class WindowsBetaPresentationTests
{
    public static void Run()
    {
        var now = DateTimeOffset.Parse("2026-10-11T12:00:00Z");
        var beta = new WindowsBetaAccessGrant(true, "windows", "native", "windows-stability", null, 5, false);
        var entitlement = Entitlement(beta);
        var view = WindowsBetaPresentation.For(entitlement, now);
        Require(view is { Title: "Бесплатное тестирование Windows", ShowCheckout: false, ShowSubscription: false } &&
            view.Period == "Дата окончания пока не назначена." &&
            view.SubscriptionNote.Contains("оплата не требуется", StringComparison.Ordinal),
            "A server-confirmed indefinite Windows beta must show free access without a paywall or an invented end date.");

        var paid = entitlement with { Active = true, VpnAccess = true, PlanId = "vex-monthly" };
        var paidView = WindowsBetaPresentation.For(paid, now);
        Require(paidView is { ShowCheckout: true, ShowSubscription: true } &&
            paidView.SubscriptionNote.Contains("подписка отображается отдельно", StringComparison.Ordinal) &&
            !paidView.SubscriptionNote.Contains("списан", StringComparison.Ordinal) &&
            !paidView.SubscriptionNote.Contains("отмен", StringComparison.Ordinal),
            "Joining a free beta must preserve existing subscription management without promising its charges or cancellation change.");

        var previousSubscription = entitlement with { PlanId = "vex-monthly", Status = "past_due" };
        Require(WindowsBetaPresentation.For(previousSubscription, now) is
            { ShowSubscription: true, ShowCheckout: false },
            "A beta-only access grant must keep pre-existing subscription facts visible without mandatory payment.");

        Require(WindowsBetaPresentation.For(Entitlement(null), now) is null &&
            WindowsBetaPresentation.For(paid with { WindowsBeta = null }, now) is null,
            "Ordinary paid and unpaid accounts must not announce a beta without server authority.");
        foreach (var invalid in new[]
        {
            beta with { Active = false }, beta with { Platform = "macos" },
            beta with { ClientFlavor = "expo" }, beta with { RequiresPayment = true },
            beta with { RequiresPayment = null }, beta with { CampaignId = " " },
            beta with { DeviceLimit = 0 }, beta with { EndsAt = "not-a-date" },
            beta with { EndsAt = now.ToString("O") }, beta with { EndsAt = now.AddSeconds(-1).ToString("O") },
        })
            Require(WindowsBetaPresentation.For(Entitlement(invalid), now) is null,
                "Inactive, foreign, paid, incomplete, malformed or expired grants must never show free Windows access.");

        var finite = WindowsBetaPresentation.For(Entitlement(beta with { EndsAt = now.AddDays(1).ToString("O") }), now);
        Require(finite is not null && finite.Period.StartsWith("Тестирование доступно до ", StringComparison.Ordinal) &&
            finite.Period != view!.Period,
            "If the server later sets an end date, the interface must show it instead of indefinite-test copy.");

        var state = new NativeClientState(
            new VexAuthSession(new VexUser("beta-ui-user", "beta@example.test", "active"), "isolated-token", now.AddDays(1)),
            "beta-installation", "beta-device", "de-frankfurt", new WireGuardIdentity("private", "public", 1),
            CachedEntitlement: entitlement, CachedEntitlementCheckedAt: now.AddMinutes(-1),
            CachedEntitlementValidUntil: now.AddHours(23));
        Require(WindowsBetaPresentation.FromState(state, now) is not null,
            "A bounded server-confirmed access cache may show beta access offline.");
        foreach (var stale in new[]
        {
            state with { CachedEntitlementCheckedAt = null },
            state with { CachedEntitlementCheckedAt = now.AddSeconds(1) },
            state with { CachedEntitlementValidUntil = null },
            state with { CachedEntitlementValidUntil = now },
            state with { CachedEntitlementValidUntil = now.AddHours(24).AddSeconds(1) },
            state with { CachedEntitlement = Entitlement(beta with { Active = false }) },
        })
            Require(WindowsBetaPresentation.FromState(stale, now) is null,
                "A campaign persisted without a current, bounded server entitlement must not be advertised as active.");
        Require(WindowsBetaPresentation.FromState(null, now) is null,
            "Signed-out or locked users must not inherit an active beta announcement from another session.");
    }

    private static VexEntitlement Entitlement(WindowsBetaAccessGrant? beta) => new(false, null, null, "active",
        null, null, null, "inactive", null, null, null, false, beta);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

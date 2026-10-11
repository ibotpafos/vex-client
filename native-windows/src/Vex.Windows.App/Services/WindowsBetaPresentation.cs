using System.Globalization;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Services;

internal sealed record WindowsBetaSummary(
    string Title,
    string Description,
    string Period,
    string SubscriptionNote,
    bool ShowSubscription,
    bool ShowCheckout);

internal static class WindowsBetaPresentation
{
    internal static WindowsBetaSummary? FromState(NativeClientState? state, DateTimeOffset now)
    {
        // A persisted campaign alone is not an active access lease. The same
        // bounded, server-confirmed entitlement used by Connect owns the copy.
        if (state?.CachedEntitlementCheckedAt is not { } checkedAt || checkedAt > now ||
            state.CachedEntitlementValidUntil is not { } validUntil || validUntil <= now ||
            validUntil - checkedAt > TimeSpan.FromHours(24))
            return null;
        return For(state.CachedEntitlement, now);
    }

    internal static WindowsBetaSummary? For(VexEntitlement? entitlement, DateTimeOffset now)
    {
        if (entitlement?.HasWindowsBetaAccessAt(now) != true) return null;
        var period = entitlement.WindowsBeta!.EndsAt is null
            ? "Дата окончания пока не назначена."
            : "Тестирование доступно до " +
                DateTimeOffset.Parse(entitlement.WindowsBeta.EndsAt, CultureInfo.InvariantCulture)
                    .ToLocalTime().ToString("dd.MM.yyyy HH:mm", CultureInfo.InvariantCulture) + ".";
        var hasSubscription = entitlement.HasPaidAccess || !string.IsNullOrWhiteSpace(entitlement.PlanId);
        return new("Бесплатное тестирование Windows",
            "VPN в приложении Windows доступен бесплатно на время тестирования.",
            period,
            hasSubscription
                ? "Участие бесплатно. Ваша подписка отображается отдельно; управление ею доступно на сайте VEX."
                : "Участие бесплатно. Для подключения в Windows оплата не требуется.",
            hasSubscription, entitlement.HasPaidAccess);
    }
}

using System.Globalization;

namespace Vex.Windows.Client.Api;

public static class BillingSummaryBuilder
{
    private static readonly IReadOnlyList<BillingPlan> FallbackPlans =
    [
        new(
            "basic_monthly",
            "Базовый",
            "platega",
            19900,
            "RUB",
            "monthly",
            1,
            "basic",
            "active"),
        new(
            "pro_monthly",
            "Pro",
            "platega",
            49900,
            "RUB",
            "monthly",
            3,
            "pro",
            "active"),
        new(
            "family_monthly",
            "Team",
            "platega",
            149900,
            "RUB",
            "monthly",
            10,
            "team",
            "active"),
    ];

    public static BillingSummary Build(
        IReadOnlyList<BillingPlan> plans,
        VexEntitlement? entitlement)
    {
        var sourcePlans = plans.Count == 0 ? FallbackPlans : plans;
        var activePlans = sourcePlans
            .Where(plan => string.Equals(
                plan.Status,
                "active",
                StringComparison.Ordinal))
            .OrderBy(plan => plan.AmountCents)
            .ThenBy(plan => plan.Id, StringComparer.Ordinal)
            .ToArray();
        var currentPlan = CurrentPlan(activePlans, entitlement);
        var entitlementStatus = entitlement switch
        {
            null => "unknown",
            _ when entitlement.HasPaidAccess => "active",
            _ => "inactive",
        };
        var planOptions = activePlans
            .Select(plan =>
            {
                var current = currentPlan is not null &&
                    BillingPlansMatch(plan, currentPlan);
                return new BillingPlanOption(
                    plan.Id,
                    plan.Name ?? PlanLabel(plan.Tier, plan.Id),
                    plan.Provider ?? "platega",
                    $"{PlanPrice(plan)} · {DeviceLimitText(plan.DeviceLimit)}",
                    entitlementStatus == "unknown"
                        ? "Проверяем"
                        : PlanActionText(
                            plan,
                            currentPlan,
                            entitlement?.HasPaidAccess == true),
                    current,
                    current || entitlementStatus == "unknown",
                    plan.Interval,
                    DurationMonths(plan.Interval));
            })
            .ToArray();

        var subtitle = entitlementStatus switch
        {
            "active" when currentPlan is null =>
                "Подписка активна. Можно перейти на один из доступных тарифов.",
            "active" =>
                "Текущий тариф отмечен. Можно перейти на другой.",
            "unknown" =>
                "Не удалось подтвердить текущий тариф. Обновите экран через несколько секунд.",
            _ =>
                "Оплата откроется в браузере.",
        };

        return new BillingSummary(
            entitlementStatus == "active"
                ? "Управление подпиской"
                : entitlementStatus == "unknown"
                    ? "Проверяем подписку"
                    : "Выберите подписку",
            subtitle,
            "Активные тарифы сейчас недоступны.",
            entitlementStatus,
            planOptions.FirstOrDefault(plan => plan.Current),
            entitlement?.CurrentPeriodEnd,
            entitlement?.EffectiveExpiresAt,
            entitlement?.RemainingText,
            entitlement?.Status,
            planOptions);
    }

    private static BillingPlan? CurrentPlan(
        IReadOnlyList<BillingPlan> plans,
        VexEntitlement? entitlement)
    {
        if (entitlement?.HasPaidAccess != true)
        {
            return null;
        }

        var planId = (entitlement.PlanId ?? string.Empty).ToLowerInvariant();
        var tier = (entitlement.Tier ?? string.Empty).ToLowerInvariant();
        return plans.FirstOrDefault(plan =>
                   plan.Id.Equals(planId, StringComparison.OrdinalIgnoreCase))
            ?? plans.FirstOrDefault(plan =>
                   !string.IsNullOrWhiteSpace(tier) &&
                   plan.Tier.Equals(tier, StringComparison.OrdinalIgnoreCase))
            ?? plans.FirstOrDefault(plan =>
                   !string.IsNullOrWhiteSpace(tier) &&
                   plan.Id.Contains(tier, StringComparison.OrdinalIgnoreCase));
    }

    private static bool BillingPlansMatch(
        BillingPlan plan,
        BillingPlan currentPlan) =>
        string.Equals(plan.Id, currentPlan.Id, StringComparison.Ordinal);

    private static string PlanActionText(
        BillingPlan plan,
        BillingPlan? currentPlan,
        bool hasCurrent)
    {
        if (currentPlan is not null &&
            BillingPlansMatch(plan, currentPlan))
        {
            return "Текущий";
        }

        if (!hasCurrent)
        {
            return "Купить";
        }

        if (currentPlan is null)
        {
            return "Сменить";
        }

        if (plan.AmountCents > currentPlan.AmountCents)
        {
            return "Обновить";
        }

        if (plan.AmountCents < currentPlan.AmountCents)
        {
            return "Перейти";
        }

        return "Сменить";
    }

    private static string PlanPrice(BillingPlan plan)
    {
        var culture = CultureInfo.GetCultureInfo("ru-RU");
        var value = plan.AmountCents / 100m;
        return string.Format(
            culture,
            "{0:C}/{1}",
            value,
            IntervalText(plan.Interval));
    }

    private static string IntervalText(string interval) =>
        interval.ToLowerInvariant() switch
        {
            "year" or "yearly" or "annual" => "год",
            "week" or "weekly" => "нед.",
            "day" or "daily" => "день",
            _ => "мес.",
        };

    private static string DeviceLimitText(int limit)
    {
        var safeLimit = Math.Max(0, limit);
        var mod10 = safeLimit % 10;
        var mod100 = safeLimit % 100;
        if (mod10 == 1 && mod100 != 11)
        {
            return $"{safeLimit} устройство";
        }

        if (mod10 is >= 2 and <= 4 &&
            (mod100 < 12 || mod100 > 14))
        {
            return $"{safeLimit} устройства";
        }

        return $"{safeLimit} устройств";
    }

    private static int DurationMonths(string interval) =>
        interval.ToLowerInvariant() switch
        {
            "quarter" or "quarterly" => 3,
            "semiannual" => 6,
            "year" or "yearly" or "annual" => 12,
            _ => 1,
        };

    private static string PlanLabel(params string[] values)
    {
        foreach (var value in values)
        {
            var normalized = (value ?? string.Empty)
                .Trim()
                .Replace("_", "-", StringComparison.Ordinal)
                .Split('-', StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault();
            if (!string.IsNullOrWhiteSpace(normalized))
            {
                return char.ToUpperInvariant(normalized[0]) +
                    normalized[1..];
            }
        }

        return "Pro";
    }
}

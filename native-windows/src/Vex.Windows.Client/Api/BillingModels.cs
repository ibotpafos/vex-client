using System.Text.Json.Serialization;

namespace Vex.Windows.Client.Api;

public sealed record VexEntitlement(
    [property: JsonPropertyName("active")] bool Active,
    [property: JsonPropertyName("plan_id")] string? PlanId,
    [property: JsonPropertyName("display_name")] string? DisplayName,
    [property: JsonPropertyName("account_status")] string? AccountStatus,
    [property: JsonPropertyName("subscription_title")] string? SubscriptionTitle,
    [property: JsonPropertyName("subscription_subtitle")] string? SubscriptionSubtitle,
    [property: JsonPropertyName("remaining_text")] string? RemainingText,
    [property: JsonPropertyName("status")] string? Status,
    [property: JsonPropertyName("tier")] string? Tier,
    [property: JsonPropertyName("current_period_end")] string? CurrentPeriodEnd,
    [property: JsonPropertyName("effective_expires_at")] string? EffectiveExpiresAt,
    [property: JsonPropertyName("vpn_access")] bool VpnAccess)
{
    public bool HasPaidAccess => Active || VpnAccess;
}

public sealed record BillingPlan(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("provider")] string? Provider,
    [property: JsonPropertyName("amount_cents")] int AmountCents,
    [property: JsonPropertyName("currency")] string Currency,
    [property: JsonPropertyName("interval")] string Interval,
    [property: JsonPropertyName("device_limit")] int DeviceLimit,
    [property: JsonPropertyName("tier")] string Tier,
    [property: JsonPropertyName("status")] string Status);

public sealed record BillingPlanOption(
    string Id,
    string Name,
    string Provider,
    string Meta,
    string Action,
    bool Current,
    bool Disabled,
    string Interval,
    int DurationMonths);

public sealed record BillingSummary(
    string Title,
    string Subtitle,
    string EmptyMessage,
    string EntitlementStatus,
    BillingPlanOption? CurrentPlan,
    string? CurrentPeriodEnd,
    string? EffectiveExpiresAt,
    string? RemainingText,
    string? Status,
    IReadOnlyList<BillingPlanOption> Plans);

public sealed record CheckoutSession(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("plan_id")] string PlanId,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("status")] string Status);

public sealed record BillingPortalSession(
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("provider")] string? Provider,
    [property: JsonPropertyName("url")] string? Url,
    [property: JsonPropertyName("created_at")] string? CreatedAt);

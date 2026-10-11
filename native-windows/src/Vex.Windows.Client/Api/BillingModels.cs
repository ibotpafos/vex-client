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
    [property: JsonPropertyName("vpn_access")] bool VpnAccess,
    [property: JsonPropertyName("windows_beta")] WindowsBetaAccessGrant? WindowsBeta = null)
{
    public bool HasPaidAccess => Active || VpnAccess;

    [JsonIgnore]
    public bool HasWindowsBetaAccess => WindowsBeta?.IsValid == true;

    [JsonIgnore]
    public bool HasVpnAccess => HasPaidAccess || HasWindowsBetaAccess;

    [JsonIgnore]
    public DateTimeOffset? VpnAccessExpiresAt
    {
        get
        {
            var paidDate = !string.IsNullOrWhiteSpace(EffectiveExpiresAt) ? EffectiveExpiresAt : CurrentPeriodEnd;
            var paidExpiry = DateTimeOffset.TryParse(paidDate, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal, out var expiry) ? expiry : (DateTimeOffset?)null;
            if (!HasWindowsBetaAccess) return paidExpiry;
            if (WindowsBeta!.EndsAt is null) return null;
            WindowsBeta.TryReadExpiry(out var betaExpiry);
            if (!HasPaidAccess) return betaExpiry;
            return paidExpiry is null ? null : paidExpiry > betaExpiry ? paidExpiry : betaExpiry;
        }
    }

    public bool HasWindowsBetaAccessAt(DateTimeOffset now) => HasWindowsBetaAccess &&
        (WindowsBeta!.EndsAt is null || WindowsBeta.TryReadExpiry(out var expiry) && expiry > now);

    public bool HasVpnAccessAt(DateTimeOffset now) => HasVpnAccess &&
        (VpnAccessExpiresAt is not { } expiry || expiry > now);
}

/// <summary>A server-owned grant for the free native Windows stability test.</summary>
public sealed record WindowsBetaAccessGrant(
    [property: JsonPropertyName("active")] bool Active,
    [property: JsonPropertyName("platform")] string? Platform,
    [property: JsonPropertyName("client_flavor")] string? ClientFlavor,
    [property: JsonPropertyName("campaign_id")] string? CampaignId,
    [property: JsonPropertyName("ends_at")] string? EndsAt,
    [property: JsonPropertyName("device_limit")] int DeviceLimit,
    [property: JsonPropertyName("requires_payment")] bool? RequiresPayment)
{
    [JsonIgnore]
    public bool IsValid => Active && Platform == "windows" && ClientFlavor == "native" &&
        !string.IsNullOrWhiteSpace(CampaignId) && DeviceLimit > 0 && RequiresPayment == false &&
        (EndsAt is null || TryReadExpiry(out _));

    public bool TryReadExpiry(out DateTimeOffset expiry) => DateTimeOffset.TryParse(EndsAt,
        System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.AssumeUniversal, out expiry);
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

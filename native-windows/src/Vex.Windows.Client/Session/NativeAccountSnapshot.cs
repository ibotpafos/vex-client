using Vex.Windows.Client.Api;

namespace Vex.Windows.Client.Session;

public enum NativeAccountSectionAvailability { Current, Cached, Unavailable }

public sealed record NativeAccountSectionStatus(
    NativeAccountSectionAvailability Availability,
    string? ErrorCode = null)
{
    public static NativeAccountSectionStatus Current { get; } = new(NativeAccountSectionAvailability.Current);
    public bool IsCurrent => Availability == NativeAccountSectionAvailability.Current;
    public bool HasData => Availability != NativeAccountSectionAvailability.Unavailable;
}

public sealed record NativeAccountSnapshot(
    string Email,
    string LocationId,
    VexEntitlement Entitlement,
    BillingSummary BillingSummary,
    IReadOnlyList<VpnDevice> Devices,
    IReadOnlyList<VpnDeviceUsage> DeviceUsage,
    IReadOnlyList<BillingPayment> Payments)
{
    public string? UserId { get; init; }
    public IReadOnlyList<BillingPlan> BillingPlans { get; init; } = [];
    public NativeAccountSectionStatus BillingSummaryStatus { get; init; } = NativeAccountSectionStatus.Current;
    public NativeAccountSectionStatus DevicesStatus { get; init; } = NativeAccountSectionStatus.Current;
    public NativeAccountSectionStatus DeviceUsageStatus { get; init; } = NativeAccountSectionStatus.Current;
    public NativeAccountSectionStatus PaymentsStatus { get; init; } = NativeAccountSectionStatus.Current;
}

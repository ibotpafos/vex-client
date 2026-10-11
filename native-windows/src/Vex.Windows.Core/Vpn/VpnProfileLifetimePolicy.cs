namespace Vex.Windows.Core.Vpn;

public static class VpnProfileLifetimePolicy
{
    // Signed authorization covers no more than 24 hours from issue to expiry.
    public static readonly TimeSpan MaximumLifetime = TimeSpan.FromHours(24);
    public static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(2);

    // A profile issued slightly ahead of the local clock still has at most
    // 24 hours from issue to expiry. Advisory routes retain that exact expiry.
    public static readonly TimeSpan MaximumRemainingLifetime = MaximumLifetime + ClockSkew;
}

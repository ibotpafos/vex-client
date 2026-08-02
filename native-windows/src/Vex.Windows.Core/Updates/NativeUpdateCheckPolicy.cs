namespace Vex.Windows.Core.Updates;

public static class NativeUpdateCheckPolicy
{
    public static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(6);
    public static readonly TimeSpan RetryDelay = TimeSpan.FromMinutes(15);

    public static bool ShouldCheck(
        bool automaticChecksEnabled,
        DateTimeOffset? lastCheckAt,
        DateTimeOffset now)
    {
        if (!automaticChecksEnabled)
        {
            return false;
        }

        return lastCheckAt is null ||
            now - lastCheckAt.Value >= CheckInterval;
    }

    public static TimeSpan NextDelay(bool lastCheckSucceeded) =>
        lastCheckSucceeded
            ? CheckInterval
            : RetryDelay;
}

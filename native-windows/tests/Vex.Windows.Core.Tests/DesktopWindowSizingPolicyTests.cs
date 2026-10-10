using Vex.Windows.Core.Presentation;

internal static class DesktopWindowSizingPolicyTests
{
    public static void Run()
    {
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(96, 1920, 1080) == new DesktopMinimumTrackingSize(640, 540),
            "The minimum must preserve the compact Home geometry already exercised by desktop smoke.");
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(192, 3840, 2160) == new DesktopMinimumTrackingSize(1280, 1080),
            "High-DPI monitors must retain the same logical minimum rather than clip the fixed VPN control.");
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(144, 2560, 1440) == new DesktopMinimumTrackingSize(960, 810),
            "Fractional display scaling must preserve logical dimensions.");
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(192, 800, 600) == new DesktopMinimumTrackingSize(768, 568),
            "A small monitor must cap the minimum at its usable work area rather than force the window off-screen.");
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(0, 1920, 1080) == new DesktopMinimumTrackingSize(640, 540),
            "An unavailable DPI query must fall back to 96 DPI.");
        Require(DesktopWindowSizingPolicy.MinimumTrackingSize(uint.MaxValue, 800, 600) == new DesktopMinimumTrackingSize(768, 568) &&
            DesktopWindowSizingPolicy.MinimumTrackingSize(96, int.MinValue, 0) == new DesktopMinimumTrackingSize(1, 1),
            "Invalid display metadata must remain bounded and avoid arithmetic overflow in a native window callback.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

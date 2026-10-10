namespace Vex.Windows.Core.Presentation;

public readonly record struct DesktopMinimumTrackingSize(int Width, int Height);

public static class DesktopWindowSizingPolicy
{
    // This compact outer-window size is exercised by the Windows desktop smoke.
    public static DesktopMinimumTrackingSize MinimumTrackingSize(
        uint dpi,
        int workAreaWidth,
        int workAreaHeight)
    {
        var scale = (dpi == 0 ? 96 : dpi) / 96d;
        var widthLimit = Math.Max(1L, (long)workAreaWidth - 32);
        var heightLimit = Math.Max(1L, (long)workAreaHeight - 32);
        return new(
            (int)Math.Min(widthLimit, Math.Round(640 * scale)),
            (int)Math.Min(heightLimit, Math.Round(540 * scale)));
    }
}

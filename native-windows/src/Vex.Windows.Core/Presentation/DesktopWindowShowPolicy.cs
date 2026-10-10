namespace Vex.Windows.Core.Presentation;

public static class DesktopWindowShowPolicy
{
    // Win32 SW_SHOW preserves normal/maximized placement; SW_RESTORE also
    // unmaximizes an already maximized window, so use it only when minimized.
    public static int ActivationCommand(bool isMinimized) => isMinimized ? 9 : 5;
}

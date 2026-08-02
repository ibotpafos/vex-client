using Microsoft.Win32;

namespace Vex.Windows.App.Services;

public sealed class WindowsStartupService
{
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "VEX VPN";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(ValueName) is string configured &&
            string.Equals(
                configured,
                StartupCommand(),
                StringComparison.OrdinalIgnoreCase);
    }

    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(
            RunKeyPath,
            writable: true);
        if (enabled)
        {
            key.SetValue(
                ValueName,
                StartupCommand(),
                RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    private static string StartupCommand()
    {
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !Path.IsPathFullyQualified(executable))
        {
            throw new InvalidOperationException(
                "Путь приложения VEX недоступен для автозапуска.");
        }

        return $"\"{executable}\"";
    }
}

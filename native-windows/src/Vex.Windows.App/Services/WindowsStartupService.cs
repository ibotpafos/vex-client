using Microsoft.Win32;
using Vex.Windows.Core.Presentation;

namespace Vex.Windows.App.Services;

public sealed class WindowsStartupService
{
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "VEX VPN";
    private const string StartupApprovedPath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ExplorerPolicyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

    public WindowsStartupService()
    {
        if (UiPreviewContext.IsEnabled) return;
        // MSIX upgrade changes the executable directory. Migrate only this
        // package family's old registration; keep Windows' approval unchanged.
        try
        {
            var registration = CurrentRegistration();
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (key?.GetValue(ValueName) is string configured &&
                registration.IsOwnedLegacy(configured))
                key.SetValue(ValueName, registration.Command, RegistryValueKind.String);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.SecurityException or InvalidOperationException)
        {
            System.Diagnostics.Debug.WriteLine($"Startup registration migration failed: {error.GetType().Name}");
        }
    }

    public bool IsEnabled() => GetStatus() == StartupRegistrationState.Enabled;

    public StartupRegistrationState GetStatus()
    {
        if (UiPreviewContext.IsEnabled) return StartupRegistrationState.Disabled;
        var registration = CurrentRegistration();
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        var configured = key?.GetValue(ValueName);
        using var approved = Registry.CurrentUser.OpenSubKey(StartupApprovedPath);
        return StartupRegistrationPolicy.Assess(configured is not null,
            configured is string command && registration.IsOwned(command),
            StartupRegistrationPolicy.IsDisabledByUser(approved?.GetValue(ValueName) as byte[]),
            RunDisabledByPolicy(Registry.CurrentUser) || RunDisabledByPolicy(Registry.LocalMachine));
    }

    public void SetEnabled(bool enabled)
    {
        if (UiPreviewContext.IsEnabled)
            throw new InvalidOperationException("В режиме просмотра автозапуск не изменяется.");
        var registration = CurrentRegistration();
        StartupRegistrationPolicy.EnsureChangeAllowed(GetStatus(), enabled);
        using var key = Registry.CurrentUser.CreateSubKey(
            RunKeyPath,
            writable: true);
        var configured = key.GetValue(ValueName);
        if (configured is not null && (configured is not string command || !registration.IsOwned(command)))
            StartupRegistrationPolicy.EnsureChangeAllowed(StartupRegistrationState.ForeignRegistration, enabled);
        if (enabled)
        {
            key.SetValue(
                ValueName,
                registration.Command,
                RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    private static bool RunDisabledByPolicy(RegistryKey root)
    {
        using var key = root.OpenSubKey(ExplorerPolicyPath);
        return key?.GetValue("DisableCurrentUserRun") is int value && value != 0;
    }

    private static StartupRegistration CurrentRegistration()
    {
        try
        {
            var package = global::Windows.ApplicationModel.Package.Current;
            var id = package.Id;
            return new StartupRegistration(StartupRegistrationPolicy.PackagedCommand(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows), id.FamilyName),
                Path.GetDirectoryName(package.InstalledLocation.Path), id.Name, id.PublisherId);
        }
        catch (InvalidOperationException)
        {
            // Unpackaged review/development builds keep their exact CLI path.
        }
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !Path.IsPathFullyQualified(executable))
        {
            throw new InvalidOperationException(
                "Путь приложения VEX недоступен для автозапуска.");
        }

        return new StartupRegistration($"\"{executable}\"", null, null, null);
    }

    private sealed record StartupRegistration(string Command, string? WindowsAppsDirectory,
        string? PackageName, string? PublisherId)
    {
        public bool IsOwned(string command) => string.Equals(command, Command, StringComparison.OrdinalIgnoreCase) ||
            IsOwnedLegacy(command);

        public bool IsOwnedLegacy(string command) => WindowsAppsDirectory is not null &&
            StartupRegistrationPolicy.IsOwnedLegacyPackagedCommand(command, WindowsAppsDirectory,
                PackageName!, PublisherId!);
    }
}

using System.Text.RegularExpressions;

namespace Vex.Windows.Core.Presentation;

public enum StartupRegistrationState
{
    Disabled,
    Enabled,
    DisabledByUser,
    DisabledByPolicy,
    ForeignRegistration,
}

public static class StartupRegistrationPolicy
{
    public static string PackagedCommand(string windowsDirectory, string packageFamilyName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(windowsDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFamilyName);
        if (windowsDirectory.Contains('"') ||
            !Regex.IsMatch(packageFamilyName, @"\A[A-Za-z0-9._-]{1,255}\z"))
        {
            throw new ArgumentException("The startup activation identity is invalid.");
        }
        var explorer = windowsDirectory.TrimEnd('\\', '/') + @"\explorer.exe";
        return $"\"{explorer}\" \"shell:AppsFolder\\{packageFamilyName}!VexWindowsApp\"";
    }

    public static bool IsOwnedLegacyPackagedCommand(string? command, string windowsAppsDirectory,
        string packageName, string publisherId)
    {
        if (string.IsNullOrWhiteSpace(command) || string.IsNullOrWhiteSpace(windowsAppsDirectory) ||
            string.IsNullOrWhiteSpace(packageName) || string.IsNullOrWhiteSpace(publisherId)) return false;
        command = command.Trim();
        if (command.Length < 3 || command[0] != '"' || command[^1] != '"' ||
            command.Count(character => character == '"') != 2) return false;
        var executable = command[1..^1].Replace('/', '\\');
        var root = windowsAppsDirectory.TrimEnd('\\', '/').Replace('/', '\\') + "\\";
        const string suffix = @"\Vex.Windows.App.exe";
        if (!executable.StartsWith(root, StringComparison.OrdinalIgnoreCase) ||
            !executable.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return false;
        var directory = executable[root.Length..^suffix.Length];
        var identityPattern = @"\A" + Regex.Escape(packageName) +
            @"_\d+\.\d+\.\d+\.\d+_(?:x64|arm64|x86|neutral)_[A-Za-z0-9._-]*_" +
            Regex.Escape(publisherId) + @"\z";
        return Regex.IsMatch(directory, identityPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    public static bool IsDisabledByUser(byte[]? approvedState) =>
        approvedState is { Length: >= 12 } && approvedState[0] is 3 or 7;

    public static StartupRegistrationState Assess(bool registrationExists, bool registrationOwned,
        bool disabledByUser, bool disabledByPolicy)
    {
        if (registrationExists && !registrationOwned) return StartupRegistrationState.ForeignRegistration;
        if (disabledByPolicy) return StartupRegistrationState.DisabledByPolicy;
        if (disabledByUser) return StartupRegistrationState.DisabledByUser;
        return registrationExists ? StartupRegistrationState.Enabled : StartupRegistrationState.Disabled;
    }

    public static void EnsureChangeAllowed(StartupRegistrationState state, bool enable)
    {
        if (state == StartupRegistrationState.ForeignRegistration)
            throw new InvalidOperationException("Запись автозапуска занята другой программой. VEX не будет изменять её.");
        if (enable && state == StartupRegistrationState.DisabledByPolicy)
            throw new InvalidOperationException("Автозапуск запрещён политикой Windows. Обратитесь к администратору.");
        if (enable && state == StartupRegistrationState.DisabledByUser)
            throw new InvalidOperationException("Автозапуск VEX отключён в Windows. Включите его в «Параметры → Приложения → Автозагрузка».");
    }
}

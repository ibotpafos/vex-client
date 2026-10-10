using Vex.Windows.Core.Presentation;

internal static class StartupRegistrationTests
{
    public static void Run()
    {
        const string family = "VEX.Native_abcdefghijklm";
        var command = StartupRegistrationPolicy.PackagedCommand(@"C:\Windows", family);
        Equal(@"""C:\Windows\explorer.exe"" ""shell:AppsFolder\VEX.Native_abcdefghijklm!VexWindowsApp""", command);
        foreach (var version in new[] { "1.2.3.4", "9.8.7.6" })
        {
            var legacy = $"\"C:\\Program Files\\WindowsApps\\VEX.Native_{version}_arm64__abcdefghijklm\\Vex.Windows.App.exe\"";
            Equal(true, StartupRegistrationPolicy.IsOwnedLegacyPackagedCommand(legacy,
                @"C:\Program Files\WindowsApps", "VEX.Native", "abcdefghijklm"));
        }
        foreach (var unowned in new[]
        {
            @"""C:\Program Files\WindowsApps\Other_1.2.3.4_x64__abcdefghijklm\Vex.Windows.App.exe""",
            @"""C:\Program Files\WindowsApps\VEX.Native_1.2.3.4_x64__foreignpublisher\Vex.Windows.App.exe""",
            @"""C:\Temp\VEX.Native_1.2.3.4_x64__abcdefghijklm\Vex.Windows.App.exe""",
            @"""C:\Program Files\WindowsApps\VEX.Native_1.2.3.4_x64__abcdefghijklm\Other.exe""",
            @"""C:\Program Files\WindowsApps\VEX.Native_1.2.3.4_x64__abcdefghijklm\Vex.Windows.App.exe"" --other",
        }) Equal(false, StartupRegistrationPolicy.IsOwnedLegacyPackagedCommand(unowned,
            @"C:\Program Files\WindowsApps", "VEX.Native", "abcdefghijklm"));

        Equal(StartupRegistrationState.Enabled, StartupRegistrationPolicy.Assess(true, true, false, false));
        Equal(StartupRegistrationState.Disabled, StartupRegistrationPolicy.Assess(false, false, false, false));
        foreach (byte disabled in new byte[] { 3, 7 })
        {
            var approval = new byte[12];
            approval[0] = disabled;
            Equal(true, StartupRegistrationPolicy.IsDisabledByUser(approval));
            Equal(StartupRegistrationState.DisabledByUser, StartupRegistrationPolicy.Assess(true, true, true, false));
            Throws(() => StartupRegistrationPolicy.EnsureChangeAllowed(StartupRegistrationState.DisabledByUser, true));
            StartupRegistrationPolicy.EnsureChangeAllowed(StartupRegistrationState.DisabledByUser, false);
        }
        Equal(false, StartupRegistrationPolicy.IsDisabledByUser(new byte[12] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
        Equal(StartupRegistrationState.DisabledByPolicy, StartupRegistrationPolicy.Assess(true, true, false, true));
        Throws(() => StartupRegistrationPolicy.EnsureChangeAllowed(StartupRegistrationState.DisabledByPolicy, true));
        foreach (bool enable in new[] { true, false })
            Throws(() => StartupRegistrationPolicy.EnsureChangeAllowed(StartupRegistrationState.ForeignRegistration, enable));
        Equal(StartupRegistrationState.ForeignRegistration, StartupRegistrationPolicy.Assess(true, false, false, false));
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
    }

    private static void Throws(Action action)
    {
        try { action(); }
        catch (InvalidOperationException) { return; }
        throw new InvalidOperationException("Expected startup policy rejection.");
    }
}

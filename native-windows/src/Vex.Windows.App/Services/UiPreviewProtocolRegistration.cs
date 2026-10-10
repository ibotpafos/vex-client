#if DEBUG
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Runtime.InteropServices;
#endif

namespace Vex.Windows.App.Services;

/// <summary>Owns one temporary Debug protocol without changing production associations.</summary>
internal static class UiPreviewProtocolRegistration
{
#if DEBUG
    private const string ParentKey = @"Software\Classes";
    private const string OwnerValue = "VexUiPreviewOwner";
    private const string SchemaValue = "VexUiPreviewSchema";
    private const string Schema = "vex.windows.ui-preview-protocol.v1";
    private const string DisplayName = "URL:VEX isolated UI preview";
    private const uint OpenLink = 0x8;
    private const uint ReadWrite = 0x2001f;
    private static string? _ownedExecutable;
    private static string? _ownedCommand;
#endif

    public static void Register()
    {
#if DEBUG
        if (!UiPreviewContext.IsEnabled) return;
        var executable = Path.GetFullPath(Environment.ProcessPath ??
            throw new InvalidOperationException("UI preview executable is unavailable."));
        // Match the Windows App SDK's encoded protocol activation argument.
        var command = $"\"{executable}\" \"----ms-protocol:%1\"";
        AssertNoExecutableReparse(executable);
        using var parent = OpenWithoutLinks(ParentKey) ??
            throw new InvalidOperationException("Current-user protocol registry is unavailable.");
        using (var existing = OpenWithoutLinks($@"{ParentKey}\{UiPreviewContext.ProtocolScheme}"))
        {
            if (existing is not null)
                throw new InvalidOperationException("A foreign UI preview protocol is already registered.");
        }
        var status = RegCreateKeyEx(parent.Handle, UiPreviewContext.ProtocolScheme,
            0, null, 0, ReadWrite, 0, out var handle, out var disposition);
        if (status != 0) { handle.Dispose(); throw new Win32Exception(status); }
        using var key = RegistryKey.FromHandle(handle);
        // REG_CREATED_NEW_KEY: refuse a registration introduced after the absence check.
        if (disposition != 1)
            throw new InvalidOperationException("UI preview protocol registration changed concurrently.");
        key.SetValue(OwnerValue, executable, RegistryValueKind.String);
        key.SetValue(SchemaValue, Schema, RegistryValueKind.String);
        key.SetValue("", DisplayName, RegistryValueKind.String);
        key.SetValue("URL Protocol", "", RegistryValueKind.String);
        using var commandKey = key.CreateSubKey(@"shell\open\command", writable: true) ??
            throw new InvalidOperationException("UI preview protocol command could not be created.");
        commandKey.SetValue("", command, RegistryValueKind.String);
        _ownedExecutable = executable;
        _ownedCommand = command;
        NotifyShell();
#endif
    }

    public static void Unregister()
    {
#if DEBUG
        var executable = _ownedExecutable;
        var expectedCommand = _ownedCommand;
        if (!UiPreviewContext.IsEnabled || executable is null || expectedCommand is null) return;
        var path = $@"{ParentKey}\{UiPreviewContext.ProtocolScheme}";
        using var key = OpenWithoutLinks(path);
        if (key is null) { _ownedExecutable = null; _ownedCommand = null; return; }
        AssertNoExecutableReparse(executable);
        using var shell = OpenWithoutLinks($@"{path}\shell");
        using var open = OpenWithoutLinks($@"{path}\shell\open");
        using var command = OpenWithoutLinks($@"{path}\shell\open\command");
        if (!HasExactNames(key.GetValueNames(), "", "URL Protocol", OwnerValue, SchemaValue) ||
            !HasExactNames(key.GetSubKeyNames(), "shell") ||
            !StringValueEquals(key, OwnerValue, executable) ||
            !StringValueEquals(key, SchemaValue, Schema) ||
            !StringValueEquals(key, "", DisplayName) ||
            !StringValueEquals(key, "URL Protocol", "") ||
            shell is null || shell.ValueCount != 0 || !HasExactNames(shell.GetSubKeyNames(), "open") ||
            open is null || open.ValueCount != 0 || !HasExactNames(open.GetSubKeyNames(), "command") ||
            command is null || !HasExactNames(command.GetValueNames(), "") || command.SubKeyCount != 0 ||
            !StringValueEquals(command, "", expectedCommand))
        {
            throw new InvalidOperationException("UI preview protocol ownership changed; cleanup was refused.");
        }
        using var parent = OpenWithoutLinks(ParentKey) ??
            throw new InvalidOperationException("Current-user protocol registry is unavailable.");
        parent.DeleteSubKeyTree(UiPreviewContext.ProtocolScheme, throwOnMissingSubKey: false);
        _ownedExecutable = null;
        _ownedCommand = null;
        NotifyShell();
#endif
    }

#if DEBUG
    private static bool HasExactNames(string[] actual, params string[] expected) =>
        actual.Length == expected.Length &&
        actual.All(value => expected.Contains(value, StringComparer.OrdinalIgnoreCase));

    private static bool StringValueEquals(RegistryKey key, string name, string expected) =>
        key.GetValueKind(name) == RegistryValueKind.String &&
        key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string value &&
        string.Equals(value, expected, StringComparison.Ordinal);

    private static void AssertNoExecutableReparse(string executable)
    {
        for (string? path = executable; !string.IsNullOrEmpty(path); path = Path.GetDirectoryName(path))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("UI preview executable path contains a reparse point.");
        }
    }

    private static RegistryKey? OpenWithoutLinks(string path)
    {
        var current = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Default);
        try
        {
            foreach (var segment in path.Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                // Inspect each registry component itself, including ancestors, without following links.
                var status = RegOpenKeyEx(current.Handle, segment, OpenLink, ReadWrite, out var handle);
                if (status != 0)
                {
                    handle.Dispose();
                    if (status is 2 or 3) { current.Dispose(); return null; }
                    throw new Win32Exception(status);
                }
                var next = RegistryKey.FromHandle(handle);
                current.Dispose();
                current = next;
                if (current.GetValueNames().Contains("SymbolicLinkValue", StringComparer.OrdinalIgnoreCase))
                    throw new InvalidOperationException("UI preview registry path contains a symbolic link.");
            }
            return current;
        }
        catch { current.Dispose(); throw; }
    }

    private static void NotifyShell() => SHChangeNotify(0x08000000, 0, 0, 0);

    [DllImport("advapi32.dll", EntryPoint = "RegOpenKeyExW", CharSet = CharSet.Unicode)]
    private static extern int RegOpenKeyEx(SafeRegistryHandle parent, string path,
        uint options, uint access, out SafeRegistryHandle key);

    [DllImport("advapi32.dll", EntryPoint = "RegCreateKeyExW", CharSet = CharSet.Unicode)]
    private static extern int RegCreateKeyEx(SafeRegistryHandle parent, string path,
        uint reserved, string? keyClass, uint options, uint access, nint security,
        out SafeRegistryHandle key, out uint disposition);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(uint eventId, uint flags, nint item1, nint item2);
#endif
}

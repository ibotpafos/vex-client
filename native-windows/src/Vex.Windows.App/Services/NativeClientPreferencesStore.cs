using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.App.Services;

public sealed record NativeClientPreferences(
    bool AutoLaunchEnabled,
    bool AutoServerEnabled,
    bool SmartRoutingEnabled,
    bool AntiLeakEnabled,
    bool AutoRecoveryEnabled,
    string InterfaceLanguage,
    string? SelectedLocationId,
    bool AutoUpdatesEnabled = true)
{
    public static NativeClientPreferences Default { get; } =
        new(
            AutoLaunchEnabled: false,
            AutoServerEnabled: true,
            SmartRoutingEnabled: true,
            AntiLeakEnabled: true,
            AutoRecoveryEnabled: true,
            InterfaceLanguage: "ru",
            SelectedLocationId: null,
            AutoUpdatesEnabled: true);
}

public sealed class NativeClientPreferencesStore
{
    private static readonly byte[] Entropy =
        "VEX.Windows.Native.Preferences.v1"u8.ToArray();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
    };

    private readonly object _sync = new();
    private readonly string _path;
    private NativeClientPreferences _current;

    public NativeClientPreferencesStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "VEX",
            "VPN",
            "preferences.v1.dpapi");
        _current = Load();
    }

    public event EventHandler? Changed;

    public NativeClientPreferences Current
    {
        get
        {
            lock (_sync)
            {
                return _current;
            }
        }
    }

    public NativeClientPreferences Update(
        Func<NativeClientPreferences, NativeClientPreferences> update)
    {
        ArgumentNullException.ThrowIfNull(update);
        NativeClientPreferences next;
        lock (_sync)
        {
            next = Normalize(update(_current));
            Save(next);
            _current = next;
        }

        Changed?.Invoke(this, EventArgs.Empty);
        return next;
    }

    private NativeClientPreferences Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return NativeClientPreferences.Default;
            }

            var protectedValue = File.ReadAllBytes(_path);
            var clearValue = ProtectedData.Unprotect(
                protectedValue,
                Entropy,
                DataProtectionScope.CurrentUser);
            try
            {
                var preferences =
                    JsonSerializer.Deserialize<NativeClientPreferences>(
                        clearValue,
                        JsonOptions) ??
                    NativeClientPreferences.Default;
                using var document = JsonDocument.Parse(clearValue);
                if (!document.RootElement.TryGetProperty(
                        nameof(NativeClientPreferences.AutoUpdatesEnabled),
                        out _))
                {
                    preferences = preferences with
                    {
                        AutoUpdatesEnabled = true,
                    };
                }

                return Normalize(preferences);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(clearValue);
            }
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or CryptographicException
                or JsonException)
        {
            return NativeClientPreferences.Default;
        }
    }

    private void Save(NativeClientPreferences preferences)
    {
        var clearValue = JsonSerializer.SerializeToUtf8Bytes(
            preferences,
            JsonOptions);
        try
        {
            var protectedValue = ProtectedData.Protect(
                clearValue,
                Entropy,
                DataProtectionScope.CurrentUser);
            var directory = Path.GetDirectoryName(_path)!;
            Directory.CreateDirectory(directory);
            var temporaryPath = _path + ".tmp";
            File.WriteAllBytes(temporaryPath, protectedValue);
            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    private static NativeClientPreferences Normalize(
        NativeClientPreferences preferences) =>
        preferences with
        {
            InterfaceLanguage =
                string.Equals(
                    preferences.InterfaceLanguage,
                    "en",
                    StringComparison.OrdinalIgnoreCase)
                    ? "en"
                    : "ru",
            SelectedLocationId =
                string.IsNullOrWhiteSpace(preferences.SelectedLocationId)
                    ? null
                    : preferences.SelectedLocationId.Trim(),
        };
}

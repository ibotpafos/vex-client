using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.App.Auth;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Services;

public sealed record WindowsHelloStatus(
    bool IsAvailable,
    string Label,
    bool IsRequired,
    ClientStateAccessKind AccessKind);

public sealed class ProtectedClientStateStore :
    IClientStateStore,
    IDeviceIdentityProvider
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("VEX Windows client state v1");
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    private readonly WindowsHelloAuthService _windowsHelloAuth;
    private readonly string _stateFile;
    private readonly string _installationIdFile;
    private readonly string _deviceStateFile;
    private readonly string _deviceIdentityFile;
    private readonly string _windowsHelloPreferenceFile;
    private bool _windowsHelloRequired;
    private bool _sessionUnlocked;

    public ProtectedClientStateStore(
        WindowsHelloAuthService? windowsHelloAuth = null)
    {
        _windowsHelloAuth =
            windowsHelloAuth ??
            new WindowsHelloAuthService();
        var localData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        _stateFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "client-state.bin");
        _installationIdFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "installation-id.bin");
        _deviceStateFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "device-state.bin");
        _deviceIdentityFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "device-identity.bin");
        _windowsHelloPreferenceFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "windows-hello.bin");
        _windowsHelloRequired =
            LoadProtected<StoredWindowsHelloPreference>(
                _windowsHelloPreferenceFile)?.Enabled ??
            false;
        _sessionUnlocked = !_windowsHelloRequired;
    }

    public ClientStateAccessKind GetAccessState()
    {
        if (!File.Exists(_stateFile))
        {
            return ClientStateAccessKind.Missing;
        }

        if (!_windowsHelloRequired || _sessionUnlocked)
        {
            return ClientStateAccessKind.Available;
        }

        return ClientStateAccessKind.Locked;
    }

    public async Task<WindowsHelloStatus> GetWindowsHelloStatusAsync(
        CancellationToken cancellationToken)
    {
        var availability = await _windowsHelloAuth.GetAvailabilityAsync(
            cancellationToken).ConfigureAwait(false);
        return new WindowsHelloStatus(
            availability.IsAvailable,
            availability.Label,
            _windowsHelloRequired,
            GetAccessState());
    }

    public async Task EnableWindowsHelloAsync(
        nint windowHandle,
        CancellationToken cancellationToken)
    {
        if (GetAccessState() == ClientStateAccessKind.Missing)
        {
            throw new InvalidOperationException(
                "Сначала выполните вход и сохраните локальную сессию.");
        }

        var availability = await _windowsHelloAuth.GetAvailabilityAsync(
            cancellationToken).ConfigureAwait(false);
        if (!availability.IsAvailable)
        {
            throw new InvalidOperationException(
                "Windows Hello недоступен на этом устройстве.");
        }

        var verified = await _windowsHelloAuth.VerifyAsync(
            windowHandle,
            "Подтвердите включение Windows Hello для VEX.",
            cancellationToken).ConfigureAwait(false);
        if (!verified.Success)
        {
            throw new InvalidOperationException(
                verified.Message);
        }

        _windowsHelloRequired = true;
        _sessionUnlocked = true;
        SaveProtected(
            _windowsHelloPreferenceFile,
            new StoredWindowsHelloPreference(
                Enabled: true));
    }

    public async Task UnlockAsync(
        nint windowHandle,
        CancellationToken cancellationToken)
    {
        if (!_windowsHelloRequired)
        {
            _sessionUnlocked = true;
            return;
        }

        if (GetAccessState() == ClientStateAccessKind.Missing)
        {
            throw new InvalidOperationException(
                "Сохраненная сессия не найдена.");
        }

        var verified = await _windowsHelloAuth.VerifyAsync(
            windowHandle,
            "Подтвердите вход в VEX через Windows Hello.",
            cancellationToken).ConfigureAwait(false);
        if (!verified.Success)
        {
            throw new InvalidOperationException(
                verified.Message);
        }

        _sessionUnlocked = true;
    }

    public async Task DisableWindowsHelloAsync(
        nint windowHandle,
        CancellationToken cancellationToken)
    {
        if (_windowsHelloRequired)
        {
            var verified = await _windowsHelloAuth.VerifyAsync(
                windowHandle,
                "Подтвердите отключение Windows Hello для VEX.",
                cancellationToken).ConfigureAwait(false);
            if (!verified.Success)
            {
                throw new InvalidOperationException(
                    verified.Message);
            }
        }

        _windowsHelloRequired = false;
        _sessionUnlocked = true;
        SaveProtected(
            _windowsHelloPreferenceFile,
            new StoredWindowsHelloPreference(
                Enabled: false));
    }

    public string GetOrCreateInstallationId()
    {
        if (File.Exists(_installationIdFile))
        {
            return UnprotectString(_installationIdFile);
        }

        var installationId = "win-" +
            Guid.NewGuid().ToString("N");
        ProtectString(_installationIdFile, installationId);
        return installationId;
    }

    public NativeClientState? Load()
    {
        if (GetAccessState() != ClientStateAccessKind.Available)
        {
            return null;
        }

        var protectedState = File.ReadAllBytes(_stateFile);
        var clearState = ProtectedData.Unprotect(
            protectedState,
            Entropy,
            DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<NativeClientState>(
                clearState,
                JsonOptions);
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException(
                "The protected VEX client state is invalid.",
                error);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearState);
        }
    }

    public NativeDeviceState? LoadDevice() =>
        LoadProtected<NativeDeviceState>(_deviceStateFile);

    public Task<DeviceIdentity?> GetOrCreateAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var stored = LoadProtected<StoredDeviceIdentity>(
            _deviceIdentityFile);
        if (stored is not null &&
            stored.Version == 1 &&
            stored.KeyType == DeviceIdentity.KeyTypeP256Jwk &&
            stored.PublicKey is not null &&
            stored.PrivateKeyD is not null &&
            stored.PublicKeyX is not null &&
            stored.PublicKeyY is not null)
        {
            return Task.FromResult<DeviceIdentity?>(
                new DeviceIdentity(
                    stored.PublicKey,
                    stored.TrustLevel,
                    stored.PrivateKeyD,
                    stored.PublicKeyX,
                    stored.PublicKeyY));
        }

        var generated = DeviceIdentity.Generate();
        SaveProtected(
            _deviceIdentityFile,
            new StoredDeviceIdentity(
                1,
                generated.KeyType,
                generated.TrustLevel,
                generated.PublicKey,
                generated.ExportPrivateScalar(),
                generated.ExportPublicX(),
                generated.ExportPublicY()));
        return Task.FromResult<DeviceIdentity?>(generated);
    }

    public void Save(NativeClientState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var clearState = JsonSerializer.SerializeToUtf8Bytes(
            state,
            JsonOptions);
        try
        {
            var protectedState = ProtectedData.Protect(
                clearState,
                Entropy,
                DataProtectionScope.CurrentUser);
            var directory = Path.GetDirectoryName(_stateFile)!;
            Directory.CreateDirectory(directory);
            var temporaryFile = _stateFile + ".new";
            File.WriteAllBytes(temporaryFile, protectedState);
            File.Move(temporaryFile, _stateFile, overwrite: true);
            SaveProtected(
                _deviceStateFile,
                new NativeDeviceState(
                    state.InstallationId,
                    state.DeviceId,
                    state.LocationId,
                    state.Identity));
            _sessionUnlocked = true;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearState);
        }
    }

    public void Clear()
    {
        if (File.Exists(_stateFile))
        {
            File.Delete(_stateFile);
        }

        _sessionUnlocked = !_windowsHelloRequired;
    }

    private static T? LoadProtected<T>(string path)
    {
        if (!File.Exists(path))
        {
            return default;
        }

        var protectedValue = File.ReadAllBytes(path);
        var clearValue = ProtectedData.Unprotect(
            protectedValue,
            Entropy,
            DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<T>(
                clearValue,
                JsonOptions);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    private static void SaveProtected<T>(string path, T value)
    {
        var clearValue = JsonSerializer.SerializeToUtf8Bytes(
            value,
            JsonOptions);
        try
        {
            var protectedValue = ProtectedData.Protect(
                clearValue,
                Entropy,
                DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, protectedValue);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    private static string UnprotectString(string path)
    {
        var protectedValue = File.ReadAllBytes(path);
        var clearValue = ProtectedData.Unprotect(
            protectedValue,
            Entropy,
            DataProtectionScope.CurrentUser);
        try
        {
            return Encoding.UTF8.GetString(clearValue);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    private static void ProtectString(string path, string value)
    {
        var clearValue = Encoding.UTF8.GetBytes(value);
        try
        {
            var protectedValue = ProtectedData.Protect(
                clearValue,
                Entropy,
                DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, protectedValue);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    private sealed record StoredDeviceIdentity(
        int Version,
        string KeyType,
        string TrustLevel,
        string PublicKey,
        byte[] PrivateKeyD,
        byte[] PublicKeyX,
        byte[] PublicKeyY);

    private sealed record StoredWindowsHelloPreference(
        bool Enabled);
}

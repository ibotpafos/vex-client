using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.App.Auth;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;

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
    private bool _sessionCacheUnavailable;

    public string? StoredSessionError { get; private set; }

    public ProtectedClientStateStore(
        WindowsHelloAuthService? windowsHelloAuth = null,
        string? stateDirectory = null)
    {
        _windowsHelloAuth =
            windowsHelloAuth ??
            new WindowsHelloAuthService();
        var directory = stateDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VEX", "VPN");
        _stateFile = Path.Combine(directory, "client-state.bin");
        _installationIdFile = Path.Combine(directory, "installation-id.bin");
        _deviceStateFile = Path.Combine(directory, "device-state.bin");
        _deviceIdentityFile = Path.Combine(directory, "device-identity.bin");
        _windowsHelloPreferenceFile = Path.Combine(directory, "windows-hello.bin");
        var helloPreference = ReadProtected<StoredWindowsHelloPreference>(_windowsHelloPreferenceFile);
        _windowsHelloRequired = helloPreference.Kind switch
        {
            ProtectedFileReadKind.Missing => false,
            ProtectedFileReadKind.Available => helloPreference.Value!.Enabled,
            _ => true,
        };
        if (helloPreference.Kind is ProtectedFileReadKind.Unusable or ProtectedFileReadKind.Unavailable)
        {
            StoredSessionError = "Параметры Windows Hello недоступны. Сохраненная сессия остается заблокированной.";
        }
        _sessionUnlocked = !_windowsHelloRequired;
    }

    public ClientStateAccessKind GetAccessState()
    {
        try
        {
            File.GetAttributes(_stateFile);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return ClientStateAccessKind.Missing;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _sessionCacheUnavailable = true;
            StoredSessionError = "Сохраненные данные VEX недоступны. Проверьте доступ к папке приложения и повторите запуск.";
            return ClientStateAccessKind.Missing;
        }

        if (!_windowsHelloRequired || _sessionUnlocked)
        {
            return _sessionCacheUnavailable
                ? ClientStateAccessKind.Missing
                : ClientStateAccessKind.Available;
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
        try
        {
            var stored = UnprotectString(_installationIdFile);
            return !string.IsNullOrWhiteSpace(stored)
                ? stored
                : throw new JsonException("Сохраненный идентификатор VEX поврежден.");
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            var installationId = "win-" + Guid.NewGuid().ToString("N");
            ProtectString(_installationIdFile, installationId);
            return installationId;
        }
    }

    public NativeClientState? Load()
    {
        if (GetAccessState() != ClientStateAccessKind.Available)
        {
            return null;
        }

        var result = ProtectedStateFileReader.Read<NativeClientState>(
            _stateFile,
            Unprotect,
            JsonOptions,
            state => state.Session?.User is not null &&
                !string.IsNullOrWhiteSpace(state.Session.User.Id) &&
                !string.IsNullOrWhiteSpace(state.Session.User.Email) &&
                !string.IsNullOrWhiteSpace(state.Session.AccessToken) &&
                !string.IsNullOrWhiteSpace(state.InstallationId) &&
                !string.IsNullOrWhiteSpace(state.DeviceId) &&
                !string.IsNullOrWhiteSpace(state.LocationId) &&
                state.Identity is { KeyEpoch: > 0 } &&
                !string.IsNullOrWhiteSpace(state.Identity.PrivateKey) &&
                !string.IsNullOrWhiteSpace(state.Identity.PublicKey));
        if (result.Kind is ProtectedFileReadKind.Unusable or ProtectedFileReadKind.Unavailable)
        {
            _sessionCacheUnavailable = true;
            StoredSessionError = result.Kind == ProtectedFileReadKind.Unavailable
                ? "Сохраненные данные VEX недоступны. Проверьте доступ к папке приложения и повторите запуск."
                : "Сохраненная сессия повреждена или недоступна для этого пользователя Windows. Выполните вход заново.";
            return null;
        }
        StoredSessionError = null;
        return result.Value;
    }

    public NativeDeviceState? LoadDevice() =>
        LoadProtected<NativeDeviceState>(_deviceStateFile);

    public Task<DeviceIdentity?> GetOrCreateAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var stored = LoadProtected<StoredDeviceIdentity>(
            _deviceIdentityFile);
        if (stored is not null)
        {
            if (stored.Version != 1 ||
                stored.KeyType != DeviceIdentity.KeyTypeP256Jwk ||
                string.IsNullOrWhiteSpace(stored.PublicKey) ||
                string.IsNullOrWhiteSpace(stored.TrustLevel) ||
                stored.PrivateKeyD is not { Length: 32 } ||
                stored.PublicKeyX is not { Length: 32 } ||
                stored.PublicKeyY is not { Length: 32 })
            {
                throw new JsonException("Сохраненный ключ устройства VEX поврежден.");
            }
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
            _sessionCacheUnavailable = false;
            StoredSessionError = null;
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
        _sessionCacheUnavailable = false;
        StoredSessionError = null;
    }

    private static T? LoadProtected<T>(string path)
    {
        var result = ReadProtected<T>(path);
        if (result.Error is not null)
        {
            // Device keys remain strict: a failed read must never generate a
            // replacement identity over a temporarily inaccessible file.
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(result.Error).Throw();
        }
        return result.Value;
    }

    private static ProtectedFileReadResult<T> ReadProtected<T>(string path) =>
        ProtectedStateFileReader.Read<T>(path, Unprotect, JsonOptions);

    private static byte[] Unprotect(byte[] value) =>
        ProtectedData.Unprotect(value, Entropy, DataProtectionScope.CurrentUser);

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
        [property: System.Text.Json.Serialization.JsonRequired] bool Enabled);
}

using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Updates;
using Vex.Windows.Core.Updates;

namespace Vex.Windows.App.Services;

public sealed class NativeUpdateService
{
    private static readonly Uri ProductionOrigin =
        new("https://downloads.vexguard.app/windows/native/", UriKind.Absolute);

    private readonly WindowsUpdateCoordinator? _coordinator;
    private readonly string _downloadsFallbackUrl;
    private readonly string _stagingRoot;
    private readonly int _rolloutBucket;
    private readonly WindowsUpdateRollbackStateStore _rollbackStateStore;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private bool _rollbackPersistenceFailed;

    public NativeUpdateService(string installationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installationId);
        _downloadsFallbackUrl = "https://vexguard.app/downloads";
        _rolloutBucket = ComputeRolloutBucket(installationId);
        var stateRoot = UiPreviewContext.StateDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VEX", "VPN");
        _stagingRoot = Path.Combine(stateRoot, "updates");
        _rollbackStateStore = new WindowsUpdateRollbackStateStore(
            Path.Combine(stateRoot, "update-rollback-state.bin"));

        if (UiPreviewContext.IsEnabled)
        {
            CurrentSnapshot = NativeUpdateSnapshot.NoUpdate(CurrentVersion(), "stable",
                RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(), "Предпросмотр интерфейса");
            return;
        }

        try
        {
            var configuration = BuildConfiguration();
            CurrentSnapshot = configuration.InitialSnapshot;
            _coordinator = configuration.Coordinator;
        }
        catch (Exception error) when (NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            // Broken local trust/rollback state disables this updater without
            // destroying it or preventing account and recovery UI from opening.
            CurrentSnapshot = NativeUpdateSnapshot.Disabled(CurrentVersion(), "stable",
                RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
                "Проверка обновлений недоступна: " + error.Message);
        }
    }

    public NativeUpdateSnapshot CurrentSnapshot { get; private set; }

    public event EventHandler? Changed;

    public string DownloadsFallbackUrl => _downloadsFallbackUrl;

    public async Task<NativeUpdateSnapshot> RefreshAsync(
        CancellationToken cancellationToken)
    {
        if (_coordinator is null)
        {
            return CurrentSnapshot;
        }

        await _operationGate.WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        NativeUpdateSnapshot? verifiedSnapshot = null;
        try
        {
            var assessment = await _coordinator.CheckForUpdateAsync(
                cancellationToken);
            verifiedSnapshot = assessment.UpdateAvailable
                ? NativeUpdateSnapshot.Available(assessment.CurrentVersion, assessment.Release!,
                    assessment.CurrentChannel, assessment.CurrentArchitecture, assessment.Release!.Required)
                : NativeUpdateSnapshot.NoUpdate(assessment.CurrentVersion, assessment.CurrentChannel,
                    assessment.CurrentArchitecture, assessment.Reason);
            _rollbackPersistenceFailed = true;
            _rollbackStateStore.Save(assessment.RollbackState);
            _coordinator.SetRollbackState(assessment.RollbackState);
            _rollbackPersistenceFailed = false;
            SetSnapshot(verifiedSnapshot);
        }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
            NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            SetSnapshot(NativeUpdateSnapshot.ErrorFrom(
                verifiedSnapshot is { UpdateAvailable: true, Required: true } ? verifiedSnapshot : CurrentSnapshot,
                error.Message));
        }
        finally
        {
            _operationGate.Release();
        }

        return CurrentSnapshot;
    }

    public async Task<NativeUpdateSnapshot> PrepareAndLaunchAsync(
        CancellationToken cancellationToken)
    {
        if (_coordinator is null)
        {
            return CurrentSnapshot;
        }

        var snapshot = CurrentSnapshot;
        if (!snapshot.UpdateAvailable || _rollbackPersistenceFailed)
        {
            snapshot = await RefreshAsync(cancellationToken);
            if (!snapshot.UpdateAvailable || _rollbackPersistenceFailed)
            {
                return snapshot;
            }
        }

        await _operationGate.WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        try
        {
            var staged = await _coordinator.DownloadAndStageProvisioningAsync(
                snapshot.Release!,
                _stagingRoot,
                cancellationToken);
            LaunchBootstrap(staged);
            SetSnapshot(NativeUpdateSnapshot.InstallerLaunched(
                snapshot.CurrentVersion,
                snapshot.Channel,
                snapshot.Architecture,
                snapshot.Release!.Version,
                staged.PackagePath));
        }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
            NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            SetSnapshot(NativeUpdateSnapshot.ErrorFrom(
                snapshot,
                error.Message));
        }
        finally
        {
            _operationGate.Release();
        }

        return CurrentSnapshot;
    }

    private void SetSnapshot(NativeUpdateSnapshot snapshot)
    {
        CurrentSnapshot = snapshot;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static void LaunchBootstrap(
        WindowsStagedProvisioningBundle staged)
    {
        using var owner = WindowsIdentity.GetCurrent();
        var ownerSid = owner.User?.Value ??
            throw new InvalidOperationException("Не удалось определить владельца установки Windows.");
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(staged.BootstrapPath),
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("AllSigned");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(staged.BootstrapPath);
        startInfo.ArgumentList.Add("-Phase");
        startInfo.ArgumentList.Add("User");
        startInfo.ArgumentList.Add("-Action");
        startInfo.ArgumentList.Add("Install");
        startInfo.ArgumentList.Add("-PackagePath");
        startInfo.ArgumentList.Add(staged.PackagePath);
        startInfo.ArgumentList.Add("-MetadataPath");
        startInfo.ArgumentList.Add(staged.PackageMetadataPath);
        startInfo.ArgumentList.Add("-OwnerSid");
        startInfo.ArgumentList.Add(ownerSid);
        startInfo.ArgumentList.Add("-RelaunchAfterInstall");
        _ = Process.Start(startInfo) ??
            throw new InvalidOperationException(
                "Windows update bootstrap could not be launched.");
    }

    private (
        WindowsUpdateCoordinator? Coordinator,
        NativeUpdateSnapshot InitialSnapshot)
        BuildConfiguration()
    {
        var channel = WindowsUpdateManifestVerifier.NormalizeChannel(
            Environment.GetEnvironmentVariable("VEX_WINDOWS_UPDATE_CHANNEL") ??
            "stable");

        string architecture;
        try
        {
            architecture = RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X64 => "x64",
                Architecture.Arm64 => "arm64",
                _ => throw new InvalidOperationException(
                    $"Unsupported Windows client architecture '{RuntimeInformation.ProcessArchitecture}'."),
            };
        }
        catch (InvalidOperationException error)
        {
            return (
                null,
                NativeUpdateSnapshot.Disabled(
                    currentVersion: CurrentVersion(),
                    channel: channel,
                    architecture: "unknown",
                    reason: error.Message));
        }

        var trustedOrigin =
#if DEBUG
            Uri.TryCreate(
                Environment.GetEnvironmentVariable("VEX_WINDOWS_UPDATE_ORIGIN"),
                UriKind.Absolute,
                out var debugOrigin)
                ? debugOrigin
                : ProductionOrigin;
#else
            ProductionOrigin;
#endif

        if (!string.Equals(
                trustedOrigin.Scheme,
                "https",
                StringComparison.OrdinalIgnoreCase))
        {
            return (
                null,
                NativeUpdateSnapshot.Disabled(
                    CurrentVersion(),
                    channel,
                    architecture,
                    "Pinned update origin must use https."));
        }

        var keyringPath =
#if DEBUG
            Environment.GetEnvironmentVariable("VEX_WINDOWS_UPDATE_KEYRING_PATH") ??
            Path.Combine(AppContext.BaseDirectory, "update-signing-keyring.json");
#else
            Path.Combine(AppContext.BaseDirectory, "update-signing-keyring.json");
#endif

        if (!File.Exists(keyringPath))
        {
            return (
                null,
                NativeUpdateSnapshot.Disabled(
                    CurrentVersion(),
                    channel,
                    architecture,
                    $"Pinned update keyring is missing at '{keyringPath}'."));
        }

        var keyring = WindowsUpdateKeyring.Parse(
            File.ReadAllText(keyringPath));
        if (keyring.Schema != WindowsUpdateConstants.KeyringSchema || keyring.Keys is not { Count: > 0 } ||
            keyring.Keys.Any(key => key is null || string.IsNullOrWhiteSpace(key.KeyId) ||
                key.Algorithm != WindowsUpdateConstants.SupportedAlgorithm ||
                string.IsNullOrWhiteSpace(key.SubjectPublicKeyInfoBase64)) ||
            keyring.Keys.Select(key => key.KeyId).Distinct(StringComparer.Ordinal).Count() != keyring.Keys.Count)
            throw new InvalidOperationException("Pinned update keyring is invalid.");
        foreach (var key in keyring.Keys)
        {
            using var verifier = ECDsa.Create();
            verifier.ImportSubjectPublicKeyInfo(Convert.FromBase64String(key.SubjectPublicKeyInfoBase64), out _);
            if (verifier.KeySize != 256)
                throw new InvalidOperationException("Pinned update key must use P-256.");
        }
        var manifestUri = new Uri(
            trustedOrigin,
            $"{channel}/{architecture}/update.json");
        var signatureUri = new Uri(
            trustedOrigin,
            $"{channel}/{architecture}/update.json.sig");
        WindowsUpdateRollbackState? rollbackState;
        try
        {
            rollbackState = _rollbackStateStore.Load();
        }
        catch (InvalidOperationException error)
        {
            return (
                null,
                NativeUpdateSnapshot.Disabled(
                    CurrentVersion(),
                    channel,
                    architecture,
                    error.Message));
        }

        var options = new WindowsUpdateVerificationOptions(
            trustedOrigin,
            channel,
            architecture,
            CurrentVersion(),
            keyring,
            _rolloutBucket,
            rollbackState);

        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression =
                DecompressionMethods.Brotli |
                DecompressionMethods.GZip |
                DecompressionMethods.Deflate,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        handler.SslOptions.CertificateRevocationCheckMode =
            X509RevocationMode.Online;
        var httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(30),
        };
        var coordinator = new WindowsUpdateCoordinator(
            httpClient,
            options,
            manifestUri,
            signatureUri);
        return (
            coordinator,
            NativeUpdateSnapshot.Configured(
                CurrentVersion(),
                channel,
                architecture));
    }

    private static string CurrentVersion() =>
        typeof(App).Assembly.GetName().Version?.ToString() ??
        "0.0.0.0";

    private static int ComputeRolloutBucket(string installationId)
    {
        var digest = SHA256.HashData(
            Encoding.UTF8.GetBytes(installationId));
        return (int)(
            BinaryPrimitives.ReadUInt32BigEndian(digest) %
            100);
    }
}

internal sealed class WindowsUpdateRollbackStateStore
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("VEX Windows update rollback state v1");
    private readonly string _path;

    public WindowsUpdateRollbackStateStore(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _path = path;
    }

    public WindowsUpdateRollbackState? Load()
    {
        if (!File.Exists(_path))
        {
            return null;
        }

        try
        {
            var protectedBytes = File.ReadAllBytes(_path);
            var clearBytes = ProtectedData.Unprotect(
                protectedBytes,
                Entropy,
                DataProtectionScope.CurrentUser);
            try
            {
                var state = JsonSerializer.Deserialize<
                    WindowsUpdateRollbackState>(clearBytes) ??
                    throw InvalidState();
                if (state.HighestManifestRevision < 0 ||
                    string.IsNullOrWhiteSpace(state.RequiredVersionFloor))
                {
                    throw InvalidState();
                }

                _ = WindowsUpdateManifestVerifier.ParseVersion(
                    state.RequiredVersionFloor,
                    "persisted_required_version_floor");
                return state;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(clearBytes);
            }
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                CryptographicException or
                JsonException or
                InvalidOperationException)
        {
            throw InvalidState(error);
        }
    }

    public void Save(WindowsUpdateRollbackState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var clearBytes = JsonSerializer.SerializeToUtf8Bytes(state);
        try
        {
            var protectedBytes = ProtectedData.Protect(
                clearBytes,
                Entropy,
                DataProtectionScope.CurrentUser);
            var directory = Path.GetDirectoryName(_path) ??
                throw InvalidState();
            Directory.CreateDirectory(directory);
            var temporaryPath = $"{_path}.{Guid.NewGuid():N}.tmp";
            try
            {
                File.WriteAllBytes(temporaryPath, protectedBytes);
                RestrictToCurrentUser(temporaryPath);
                File.Move(temporaryPath, _path, overwrite: true);
            }
            finally
            {
                File.Delete(temporaryPath);
                CryptographicOperations.ZeroMemory(protectedBytes);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }

    private static void RestrictToCurrentUser(string path)
    {
        var identity = WindowsIdentity.GetCurrent().User ??
            throw InvalidState();
        var security = new FileSecurity();
        security.SetAccessRuleProtection(
            isProtected: true,
            preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            identity,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(
                WellKnownSidType.LocalSystemSid,
                null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(
            new FileInfo(path),
            security);
    }

    private static InvalidOperationException InvalidState(
        Exception? inner = null) =>
        new(
            "Windows update rollback state is missing or invalid; updates are disabled.",
            inner);
}

public sealed record NativeUpdateSnapshot(
    string State,
    string CurrentVersion,
    string Channel,
    string Architecture,
    bool UpdateAvailable,
    WindowsUpdateRelease? Release,
    bool Required,
    string? Message,
    string? StagedPackagePath)
{
    public static NativeUpdateSnapshot Configured(
        string currentVersion,
        string channel,
        string architecture) =>
        new(
            "configured",
            currentVersion,
            channel,
            architecture,
            UpdateAvailable: false,
            Release: null,
            Required: false,
            Message: "Проверка обновлений готова.",
            StagedPackagePath: null);

    public static NativeUpdateSnapshot Disabled(
        string currentVersion,
        string channel,
        string architecture,
        string reason) =>
        new(
            "disabled",
            currentVersion,
            channel,
            architecture,
            UpdateAvailable: false,
            Release: null,
            Required: false,
            Message: reason,
            StagedPackagePath: null);

    public static NativeUpdateSnapshot NoUpdate(
        string currentVersion,
        string channel,
        string architecture,
        string reason) =>
        new(
            "current",
            currentVersion,
            channel,
            architecture,
            UpdateAvailable: false,
            Release: null,
            Required: false,
            Message: reason,
            StagedPackagePath: null);

    public static NativeUpdateSnapshot Available(
        string currentVersion,
        WindowsUpdateRelease release,
        string channel,
        string architecture,
        bool required) =>
        new(
            "available",
            CurrentVersion: currentVersion,
            Channel: channel,
            Architecture: architecture,
            UpdateAvailable: true,
            Release: release,
            Required: required,
            Message: release.Changelog,
            StagedPackagePath: null);

    public static NativeUpdateSnapshot InstallerLaunched(
        string currentVersion,
        string channel,
        string architecture,
        string availableVersion,
        string stagedPackagePath) =>
        new(
            "installer_launched",
            currentVersion,
            channel,
            architecture,
            UpdateAvailable: true,
            Release: new WindowsUpdateRelease(
                availableVersion,
                architecture,
                PackageType: "msix",
                PackageUri: stagedPackagePath,
                PackageSha256: string.Empty,
                PackageName: string.Empty,
                Publisher: string.Empty,
                AppInstallerUri: null,
                PackageSizeBytes: null,
                MinimumSupportedVersion: null,
                Changelog: null,
                Required: false,
                RolloutPercent: null),
            Required: false,
            Message: "Пакет обновления проверен и открыт в системном установщике.",
            StagedPackagePath: stagedPackagePath);

    public static NativeUpdateSnapshot Error(
        string currentVersion,
        string channel,
        string architecture,
        string message) =>
        new(
            "error",
            currentVersion,
            channel,
            architecture,
            UpdateAvailable: false,
            Release: null,
            Required: false,
            Message: message,
            StagedPackagePath: null);

    public static NativeUpdateSnapshot ErrorFrom(
        NativeUpdateSnapshot previous,
        string message)
    {
        ArgumentNullException.ThrowIfNull(previous);
        var preserveRequiredUpdate =
            previous.UpdateAvailable &&
            previous.Required &&
            previous.Release is not null;
        return preserveRequiredUpdate
            ? previous with
            {
                State = "required_update_error",
                Message = message,
                StagedPackagePath = null,
            }
            : Error(
                previous.CurrentVersion,
                previous.Channel,
                previous.Architecture,
                message);
    }
}

using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Updates;

namespace Vex.Windows.App.Services;

public sealed partial class NativeUpdateService
{
    private static readonly Uri ProductionOrigin =
        new("https://downloads.vexguard.app/windows/native/", UriKind.Absolute);
    private readonly int _rolloutBucket;
    private readonly WindowsUpdateRollbackStateStore? _rollbackStateStore;

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
        _saveRollbackState = _rollbackStateStore.Save;
        _launchBootstrap = LaunchBootstrap;

        if (UiPreviewContext.IsEnabled)
        {
            CurrentSnapshot = NativeUpdateSnapshot.NoUpdate(CurrentVersion(), "stable",
                RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(), "Предпросмотр интерфейса");
            return;
        }

        var configuration = InitializeWithDurableRollback(_rollbackStateStore.Load,
            BuildConfiguration, CurrentVersion(), "stable",
            RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant());
        CurrentSnapshot = configuration.InitialSnapshot;
        _coordinator = configuration.Coordinator;
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
        // Only our literal verifier runs with Bypass. It verifies the signed
        // release hashes and actual trusted signer before executing any script.
        // AllSigned can prompt for TrustedPublisher on a clean user profile,
        // which is incompatible with the unattended NonInteractive launcher.
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-EncodedCommand");
        var verifierInput = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new
        {
            BootstrapPath = staged.BootstrapPath,
            MetadataPath = staged.PackageMetadataPath,
            PackagePath = staged.PackagePath,
            BootstrapSha256 = staged.Release.BootstrapSha256,
            MetadataSha256 = staged.Release.PackageMetadataSha256,
            OwnerSid = ownerSid,
        }));
        var verifier = VerifiedBootstrapCommand.Replace("__VEX_BOOTSTRAP_INPUT__", verifierInput,
            StringComparison.Ordinal);
        startInfo.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(verifier)));
        _ = Process.Start(startInfo) ??
            throw new InvalidOperationException(
                "Windows update bootstrap could not be launched.");
    }

    private const string VerifiedBootstrapCommand = """
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        # VEX_TRUSTED_POWERSHELL_MODULES_BEGIN
        $systemModules = [IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'WindowsPowerShell', 'v1.0', 'Modules')
        $env:PSModulePath = $systemModules
        $requiredCommands = @{
            'Microsoft.PowerShell.Utility' = 'Get-FileHash'
            'Microsoft.PowerShell.Security' = 'Get-AuthenticodeSignature'
            'Microsoft.PowerShell.Management' = 'Get-Content'
        }
        foreach ($module in $requiredCommands.Keys) {
            $provider = Microsoft.PowerShell.Core\Get-Command -Name ($module + '\' + $requiredCommands[$module]) -CommandType Cmdlet -ListImported -ErrorAction SilentlyContinue
            if ($null -eq $provider) {
                $manifest = [IO.Path]::Combine($systemModules, $module, ($module + '.psd1'))
                if (-not [IO.File]::Exists($manifest)) {
                    $manifest = [IO.Path]::Combine([IO.Path]::GetDirectoryName($systemModules), ($module + '.psd1'))
                }
                Microsoft.PowerShell.Core\Import-Module -Name $manifest -Force -ErrorAction Stop
            }
        }
        # VEX_TRUSTED_POWERSHELL_MODULES_END
        $inputData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__VEX_BOOTSTRAP_INPUT__')) | Microsoft.PowerShell.Utility\ConvertFrom-Json
        $heldFiles = [Collections.Generic.List[IDisposable]]::new()
        try {
            foreach ($path in @($inputData.BootstrapPath, $inputData.MetadataPath)) {
                $heldFiles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
            }
            foreach ($pin in @(@($inputData.BootstrapPath, $inputData.BootstrapSha256),
                                @($inputData.MetadataPath, $inputData.MetadataSha256))) {
                if ([string]$pin[1] -notmatch '^[A-Fa-f0-9]{64}$' -or
                    (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath ([string]$pin[0]) -Algorithm SHA256).Hash -ne [string]$pin[1]) {
                    throw 'The Windows update bootstrap or metadata failed its signed release hash check.'
                }
            }
            $metadata = Microsoft.PowerShell.Management\Get-Content -LiteralPath $inputData.MetadataPath -Raw | Microsoft.PowerShell.Utility\ConvertFrom-Json
            if ([string]$metadata.client_certificate_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw 'The Windows update metadata signer pin is invalid.'
            }
            $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $inputData.BootstrapPath
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
                $null -eq $signature.SignerCertificate) {
                throw 'The Windows update bootstrap Authenticode signature is not trusted.'
            }
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $certificatePin = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '')
            }
            finally { $sha256.Dispose() }
            if ($certificatePin -ne [string]$metadata.client_certificate_sha256) {
                throw 'The Windows update bootstrap signer does not match the release.'
            }
            & $inputData.BootstrapPath -Phase User -Action Install -PackagePath $inputData.PackagePath -MetadataPath $inputData.MetadataPath -OwnerSid $inputData.OwnerSid -RelaunchAfterInstall
            if (-not $?) { throw 'The verified Windows update bootstrap failed.' }
        }
        finally { foreach ($heldFile in $heldFiles) { $heldFile.Dispose() } }
        """;

    private (
        WindowsUpdateCoordinator? Coordinator,
        NativeUpdateSnapshot InitialSnapshot)
        BuildConfiguration(WindowsUpdateRollbackState? rollbackState)
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
                architecture).WithRollbackState(rollbackState));
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
        try
        {
            byte[] protectedBytes;
            try
            {
                // File.Exists also returns false for access errors. Only an
                // actually absent record may be treated as a first installation.
                protectedBytes = File.ReadAllBytes(_path);
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
            {
                return null;
            }
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
                if (state.RequiredTargetVersion is { } target)
                    _ = WindowsUpdateManifestVerifier.ParseVersion(target, "persisted_required_target_version");
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

using System.Text.Json;

namespace Vex.Windows.Client.Updates;

public static class WindowsUpdateConstants
{
    public const int MaxManifestBytes = 256 * 1024;
    public const int MaxSignatureBytes = 16 * 1024;
    public const long MaxPackageBytes = 512L * 1024 * 1024;
    public const long MaxProvisioningArtifactBytes = 4L * 1024 * 1024;
    public static readonly TimeSpan MaxManifestAge = TimeSpan.FromDays(14);
    public static readonly TimeSpan MaxClockSkew = TimeSpan.FromMinutes(10);
    public const string ManifestSchema = "vex.windows-update-manifest.v1";
    public const string KeyringSchema = "vex.windows-update-keyring.v1";
    public const string SupportedAlgorithm = "ECDSA_P256_SHA256_DER";
}

public sealed record WindowsUpdateManifest(
    string Schema,
    string Channel,
    string PublishedAt,
    long? ManifestRevision,
    string? RequiredVersionFloor,
    WindowsUpdateSigningInfo Signing,
    IReadOnlyList<WindowsUpdateRelease> Releases);

public sealed record WindowsUpdateSigningInfo(
    string KeyId,
    string Algorithm);

public sealed record WindowsUpdateRelease(
    string Version,
    string Architecture,
    string PackageType,
    string PackageUri,
    string PackageSha256,
    string PackageName,
    string Publisher,
    string? AppInstallerUri,
    long? PackageSizeBytes,
    string? MinimumSupportedVersion,
    string? Changelog,
    bool Required,
    int? RolloutPercent,
    string? InstallEntrypoint = null,
    string? ServiceOwnership = null,
    bool? RawMsixProvisionsService = null,
    bool? RawAppinstallerProvisionsService = null,
    string? BootstrapUri = null,
    string? BootstrapSha256 = null,
    long? BootstrapSizeBytes = null,
    string? InstallServiceScriptUri = null,
    string? InstallServiceScriptSha256 = null,
    long? InstallServiceScriptSizeBytes = null,
    string? UninstallServiceScriptUri = null,
    string? UninstallServiceScriptSha256 = null,
    long? UninstallServiceScriptSizeBytes = null,
    string? PackageMetadataUri = null,
    string? PackageMetadataSha256 = null,
    long? PackageMetadataSizeBytes = null);

public sealed record WindowsUpdateKeyring(
    string Schema,
    IReadOnlyList<WindowsUpdatePublicKey> Keys)
{
    public static WindowsUpdateKeyring Parse(string json)
    {
        var keyring = JsonSerializer.Deserialize<WindowsUpdateKeyring>(
            json,
            WindowsUpdateJson.SerializerOptions);
        return keyring ??
            throw new InvalidOperationException(
                "Windows update keyring payload is empty.");
    }
}

public sealed record WindowsUpdatePublicKey(
    string KeyId,
    string Algorithm,
    string SubjectPublicKeyInfoBase64);

public sealed record WindowsUpdateVerificationOptions(
    Uri TrustedOrigin,
    string CurrentChannel,
    string CurrentArchitecture,
    string CurrentVersion,
    WindowsUpdateKeyring Keyring,
    int RolloutBucket = 0,
    WindowsUpdateRollbackState? RollbackState = null,
    Func<DateTimeOffset>? UtcNow = null);

public sealed record WindowsUpdateRollbackState(
    long HighestManifestRevision,
    string RequiredVersionFloor);

public sealed record WindowsUpdateAssessment(
    bool UpdateAvailable,
    string Reason,
    string CurrentVersion,
    string CurrentChannel,
    string CurrentArchitecture,
    WindowsUpdateRelease? Release,
    WindowsUpdateRollbackState RollbackState);

public sealed record WindowsStagedPackage(
    string PackagePath,
    string PackageSha256,
    WindowsUpdateRelease Release);

public sealed record WindowsStagedProvisioningBundle(
    string PackagePath,
    string BootstrapPath,
    string InstallServiceScriptPath,
    string UninstallServiceScriptPath,
    string PackageMetadataPath,
    WindowsUpdateRelease Release);

internal static class WindowsUpdateJson
{
    public static readonly JsonSerializerOptions SerializerOptions =
        new()
        {
            PropertyNameCaseInsensitive = false,
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            WriteIndented = true,
        };
}

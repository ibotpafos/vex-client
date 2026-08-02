using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.Client.Updates;

public static class WindowsUpdateManifestVerifier
{
    public static WindowsUpdateAssessment Verify(
        ReadOnlyMemory<byte> manifestBytes,
        string signatureBase64,
        WindowsUpdateVerificationOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var manifest = JsonSerializer.Deserialize<WindowsUpdateManifest>(
            manifestBytes.Span,
            WindowsUpdateJson.SerializerOptions) ??
            throw new InvalidOperationException(
                "Windows update manifest payload is empty.");
        if (options.RolloutBucket is < 0 or > 99)
        {
            throw new InvalidOperationException(
                "Windows update rollout bucket must be between 0 and 99.");
        }

        ValidateManifestEnvelope(manifest, options);
        VerifySignature(manifest, manifestBytes, signatureBase64, options.Keyring);

        var currentVersion = ParseVersion(options.CurrentVersion, "current_version");
        var rollbackState = ValidateRollbackState(
            manifest,
            options);
        var expectedChannel = NormalizeChannel(options.CurrentChannel);
        var expectedArchitecture = NormalizeArchitecture(options.CurrentArchitecture);
        var candidates = manifest.Releases
            .Where(release =>
                NormalizeArchitecture(release.Architecture) ==
                expectedArchitecture)
            .Select(release => new
            {
                Release = release,
                Version = ParseVersion(release.Version, "release.version"),
            })
            .OrderByDescending(candidate => candidate.Version)
            .ToArray();
        var rolloutExcluded = false;

        if (candidates.Length == 0)
        {
            return new WindowsUpdateAssessment(
                UpdateAvailable: false,
                Reason: "no_architecture_match",
                CurrentVersion: currentVersion.ToString(),
                CurrentChannel: expectedChannel,
                CurrentArchitecture: expectedArchitecture,
                Release: null,
                RollbackState: rollbackState);
        }

        foreach (var candidate in candidates)
        {
            ValidateRelease(
                candidate.Release,
                candidate.Version,
                options.TrustedOrigin,
                requireProvisioning: true);
            if (candidate.Version <= currentVersion)
            {
                continue;
            }

            var rolloutPercent = candidate.Release.RolloutPercent ?? 100;
            if (options.RolloutBucket >= rolloutPercent)
            {
                rolloutExcluded = true;
                continue;
            }

            if (candidate.Release.MinimumSupportedVersion is { Length: > 0 } min)
            {
                var minimumSupported = ParseVersion(
                    min,
                    "release.minimum_supported_version");
                if (candidate.Version < minimumSupported)
                {
                    throw new InvalidOperationException(
                        "Windows update release version is below its declared minimum supported version.");
                }
            }

            return new WindowsUpdateAssessment(
                UpdateAvailable: true,
                Reason: candidate.Release.Required
                    ? "required_update_available"
                    : "update_available",
                CurrentVersion: currentVersion.ToString(),
                CurrentChannel: expectedChannel,
                CurrentArchitecture: expectedArchitecture,
                Release: candidate.Release,
                RollbackState: rollbackState);
        }

        return new WindowsUpdateAssessment(
            UpdateAvailable: false,
            Reason: rolloutExcluded
                ? "rollout_not_selected"
                : "already_current",
            CurrentVersion: currentVersion.ToString(),
            CurrentChannel: expectedChannel,
            CurrentArchitecture: expectedArchitecture,
            Release: null,
            RollbackState: rollbackState);
    }

    public static string NormalizeChannel(string value)
    {
        var normalized = value.Trim().ToLowerInvariant();
        return normalized switch
        {
            "" => "stable",
            "production" => "stable",
            "local" => "stable",
            "test" => "stable",
            _ => normalized,
        };
    }

    internal static string NormalizeArchitecture(string value) =>
        value.Trim().ToLowerInvariant() switch
        {
            "x64" or "amd64" => "x64",
            "arm64" or "aarch64" => "arm64",
            _ => throw new InvalidOperationException(
                $"Unsupported Windows update architecture '{value}'."),
        };

    public static Version ParseVersion(
        string value,
        string fieldName)
    {
        var normalized = value.Trim();
        if (normalized.Length == 0)
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' is required.");
        }

        var parts = normalized.Split(
            '.',
            StringSplitOptions.RemoveEmptyEntries |
            StringSplitOptions.TrimEntries);
        if (parts.Length is < 2 or > 4)
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' must use 2-4 numeric version segments.");
        }

        if (parts.Any(part => !int.TryParse(part, out _)))
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' must be numeric.");
        }

        normalized = parts.Length switch
        {
            2 => $"{parts[0]}.{parts[1]}.0.0",
            3 => $"{parts[0]}.{parts[1]}.{parts[2]}.0",
            _ => string.Join('.', parts),
        };

        if (!Version.TryParse(normalized, out var version))
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' is invalid.");
        }

        return version;
    }

    private static WindowsUpdateRollbackState ValidateRollbackState(
        WindowsUpdateManifest manifest,
        WindowsUpdateVerificationOptions options)
    {
        var previous = options.RollbackState;
        if (manifest.ManifestRevision is null or <= 0 ||
            string.IsNullOrWhiteSpace(manifest.RequiredVersionFloor))
        {
            throw new InvalidOperationException(
                "Windows update manifest rollback metadata is missing or invalid.");
        }

        var requiredFloor = ParseVersion(
            manifest.RequiredVersionFloor,
            "required_version_floor");
        if (previous is not null)
        {
            if (manifest.ManifestRevision.Value <
                previous.HighestManifestRevision)
            {
                throw new InvalidOperationException(
                    "Windows update manifest revision was rolled back.");
            }

            var previousFloor = ParseVersion(
                previous.RequiredVersionFloor,
                "persisted_required_version_floor");
            if (requiredFloor < previousFloor)
            {
                throw new InvalidOperationException(
                    "Windows update required version floor was rolled back.");
            }
        }

        return new WindowsUpdateRollbackState(
            manifest.ManifestRevision.Value,
            requiredFloor.ToString());
    }

    private static void ValidateManifestEnvelope(
        WindowsUpdateManifest manifest,
        WindowsUpdateVerificationOptions options)
    {
        if (!string.Equals(
                manifest.Schema,
                WindowsUpdateConstants.ManifestSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Windows update manifest schema is unsupported.");
        }

        if (!string.Equals(
                NormalizeChannel(manifest.Channel),
                NormalizeChannel(options.CurrentChannel),
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Windows update manifest channel does not match the running client channel.");
        }

        if (!DateTimeOffset.TryParse(
                manifest.PublishedAt,
                out var publishedAt))
        {
            throw new InvalidOperationException(
                "Windows update manifest published_at is invalid.");
        }

        var now = options.UtcNow?.Invoke() ?? DateTimeOffset.UtcNow;
        if (publishedAt > now + WindowsUpdateConstants.MaxClockSkew)
        {
            throw new InvalidOperationException(
                "Windows update manifest publication time is in the future.");
        }

        if (now - publishedAt > WindowsUpdateConstants.MaxManifestAge)
        {
            throw new InvalidOperationException(
                "Windows update manifest is stale.");
        }

        if (manifest.Releases.Count == 0)
        {
            throw new InvalidOperationException(
                "Windows update manifest does not contain any releases.");
        }
    }

    private static void VerifySignature(
        WindowsUpdateManifest manifest,
        ReadOnlyMemory<byte> manifestBytes,
        string signatureBase64,
        WindowsUpdateKeyring keyring)
    {
        if (!string.Equals(
                keyring.Schema,
                WindowsUpdateConstants.KeyringSchema,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Windows update keyring schema is unsupported.");
        }

        if (!string.Equals(
                manifest.Signing.Algorithm,
                WindowsUpdateConstants.SupportedAlgorithm,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Windows update manifest signature algorithm is unsupported.");
        }

        var key = keyring.Keys.SingleOrDefault(candidate =>
            string.Equals(
                candidate.KeyId,
                manifest.Signing.KeyId,
                StringComparison.Ordinal) &&
            string.Equals(
                candidate.Algorithm,
                manifest.Signing.Algorithm,
                StringComparison.Ordinal))
            ?? throw new InvalidOperationException(
                $"Windows update signing key '{manifest.Signing.KeyId}' is not pinned.");

        var signature = Convert.FromBase64String(signatureBase64.Trim());
        var publicKey = Convert.FromBase64String(key.SubjectPublicKeyInfoBase64);
        using var ecdsa = ECDsa.Create();
        ecdsa.ImportSubjectPublicKeyInfo(publicKey, out _);
        if (!ecdsa.VerifyData(
                manifestBytes.Span,
                signature,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence))
        {
            throw new InvalidOperationException(
                "Windows update manifest signature verification failed.");
        }
    }

    private static void ValidateRelease(
        WindowsUpdateRelease release,
        Version releaseVersion,
        Uri trustedOrigin,
        bool requireProvisioning)
    {
        _ = releaseVersion;
        if (!string.Equals(
                release.PackageType,
                "msix",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Windows update package type must be msix.");
        }

        _ = NormalizeArchitecture(release.Architecture);
        var packageUri = RequireTrustedUri(
            release.PackageUri,
            trustedOrigin,
            "package_uri");
        RequirePathExtension(packageUri, ".msix", "package_uri");
        if (release.AppInstallerUri is { Length: > 0 })
        {
            var appInstallerUri = RequireTrustedUri(
                release.AppInstallerUri,
                trustedOrigin,
                "appinstaller_uri");
            RequirePathExtension(
                appInstallerUri,
                ".appinstaller",
                "appinstaller_uri");
        }

        if (release.PackageSha256.Length != 64 ||
            release.PackageSha256.Any(character =>
                !Uri.IsHexDigit(character)))
        {
            throw new InvalidOperationException(
                "Windows update package_sha256 must be a 64-character hex digest.");
        }

        if (string.IsNullOrWhiteSpace(release.PackageName) ||
            string.IsNullOrWhiteSpace(release.Publisher))
        {
            throw new InvalidOperationException(
                "Windows update package metadata is incomplete.");
        }

        if (release.PackageSizeBytes is null or <= 0 ||
            release.PackageSizeBytes > WindowsUpdateConstants.MaxPackageBytes)
        {
            throw new InvalidOperationException(
                "Windows update package_size_bytes is invalid.");
        }

        if (release.RolloutPercent is < 0 or > 100)
        {
            throw new InvalidOperationException(
                "Windows update rollout_percent must be between 0 and 100.");
        }

        if (requireProvisioning)
        {
            ValidateProvisioningRelease(release, trustedOrigin);
        }
    }

    private static void ValidateProvisioningRelease(
        WindowsUpdateRelease release,
        Uri trustedOrigin)
    {
        if (release.InstallEntrypoint != "elevated_bootstrap" ||
            release.ServiceOwnership != "manual_sc_bootstrap" ||
            release.RawMsixProvisionsService != false ||
            release.RawAppinstallerProvisionsService != false)
        {
            throw new InvalidOperationException(
                "Windows update release cannot provision the VPN service safely.");
        }

        ValidateProvisioningArtifact(
            release.BootstrapUri,
            release.BootstrapSha256,
            release.BootstrapSizeBytes,
            ".ps1",
            "bootstrap",
            trustedOrigin);
        ValidateProvisioningArtifact(
            release.InstallServiceScriptUri,
            release.InstallServiceScriptSha256,
            release.InstallServiceScriptSizeBytes,
            ".ps1",
            "install_service_script",
            trustedOrigin);
        ValidateProvisioningArtifact(
            release.UninstallServiceScriptUri,
            release.UninstallServiceScriptSha256,
            release.UninstallServiceScriptSizeBytes,
            ".ps1",
            "uninstall_service_script",
            trustedOrigin);
        ValidateProvisioningArtifact(
            release.PackageMetadataUri,
            release.PackageMetadataSha256,
            release.PackageMetadataSizeBytes,
            ".json",
            "package_metadata",
            trustedOrigin);
    }

    private static void ValidateProvisioningArtifact(
        string? uriValue,
        string? sha256,
        long? sizeBytes,
        string extension,
        string fieldName,
        Uri trustedOrigin)
    {
        if (string.IsNullOrWhiteSpace(uriValue) ||
            string.IsNullOrWhiteSpace(sha256) ||
            sha256.Length != 64 ||
            sha256.Any(character => !Uri.IsHexDigit(character)) ||
            sizeBytes is null or <= 0 ||
            sizeBytes > WindowsUpdateConstants.MaxProvisioningArtifactBytes)
        {
            throw new InvalidOperationException(
                $"Windows update {fieldName} metadata is invalid.");
        }

        var uri = RequireTrustedUri(
            uriValue,
            trustedOrigin,
            $"{fieldName}_uri");
        RequirePathExtension(uri, extension, $"{fieldName}_uri");
    }

    private static Uri RequireTrustedUri(
        string value,
        Uri trustedOrigin,
        string fieldName)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' must be an absolute URI.");
        }

        if (!string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' must use https.");
        }

        if (uri.Query.Length > 0 || uri.Fragment.Length > 0)
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' cannot contain query or fragment components.");
        }

        if (!string.Equals(
                uri.Host,
                trustedOrigin.Host,
                StringComparison.OrdinalIgnoreCase) ||
            uri.Port != trustedOrigin.Port)
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' does not match the pinned origin.");
        }

        var trustedPath = trustedOrigin.AbsolutePath.TrimEnd('/');
        if (trustedPath.Length > 0 &&
            !uri.AbsolutePath.StartsWith(
                trustedPath + '/',
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Windows update field '{fieldName}' is outside the pinned origin path.");
        }

        return uri;
    }

    private static void RequirePathExtension(
        Uri uri,
        string extension,
        string fieldName)
    {
        if (!uri.AbsolutePath.EndsWith(
                extension,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Windows update {fieldName} must reference an {extension} package.");
        }
    }
}

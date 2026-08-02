using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.Client.Updates;

public sealed class WindowsUpdateCoordinator
{
    private readonly HttpClient _httpClient;
    private WindowsUpdateVerificationOptions _options;
    private readonly Uri _manifestUri;
    private readonly Uri _signatureUri;

    public WindowsUpdateCoordinator(
        HttpClient httpClient,
        WindowsUpdateVerificationOptions options,
        Uri manifestUri,
        Uri signatureUri)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(manifestUri);
        ArgumentNullException.ThrowIfNull(signatureUri);

        _httpClient = httpClient;
        _options = options;
        _manifestUri = manifestUri;
        _signatureUri = signatureUri;
    }

    public void SetRollbackState(WindowsUpdateRollbackState rollbackState)
    {
        ArgumentNullException.ThrowIfNull(rollbackState);
        _options = _options with { RollbackState = rollbackState };
    }

    public async Task<WindowsUpdateAssessment> CheckForUpdateAsync(
        CancellationToken cancellationToken)
    {
        using var manifestResponse = await _httpClient.GetAsync(
            _manifestUri,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        manifestResponse.EnsureSuccessStatusCode();

        using var signatureResponse = await _httpClient.GetAsync(
            _signatureUri,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        signatureResponse.EnsureSuccessStatusCode();

        var manifestBytes = await ReadBoundedContentAsync(
            manifestResponse.Content,
            WindowsUpdateConstants.MaxManifestBytes,
            "manifest",
            cancellationToken);
        var signatureBytes = await ReadBoundedContentAsync(
            signatureResponse.Content,
            WindowsUpdateConstants.MaxSignatureBytes,
            "signature",
            cancellationToken);
        var signature = Encoding.UTF8.GetString(signatureBytes);
        return WindowsUpdateManifestVerifier.Verify(
            manifestBytes,
            signature,
            _options);
    }

    public async Task<WindowsStagedProvisioningBundle>
        DownloadAndStageProvisioningAsync(
            WindowsUpdateRelease release,
            string stagingRoot,
            CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(release);
        ValidateTrustedArtifactUri(
            new Uri(release.PackageUri, UriKind.Absolute));
        var package = await DownloadAndStagePackageAsync(
            release,
            stagingRoot,
            cancellationToken).ConfigureAwait(false);
        var releaseDirectory = Path.GetDirectoryName(package.PackagePath) ??
            throw new InvalidOperationException(
                "Windows update staging directory is invalid.");

        var bootstrap = await StageProvisioningArtifactAsync(
            release.BootstrapUri,
            release.BootstrapSha256,
            release.BootstrapSizeBytes,
            "bootstrap-native-windows.ps1",
            releaseDirectory,
            cancellationToken).ConfigureAwait(false);
        var installScript = await StageProvisioningArtifactAsync(
            release.InstallServiceScriptUri,
            release.InstallServiceScriptSha256,
            release.InstallServiceScriptSizeBytes,
            "install-vpn-service.ps1",
            releaseDirectory,
            cancellationToken).ConfigureAwait(false);
        var uninstallScript = await StageProvisioningArtifactAsync(
            release.UninstallServiceScriptUri,
            release.UninstallServiceScriptSha256,
            release.UninstallServiceScriptSizeBytes,
            "uninstall-vpn-service.ps1",
            releaseDirectory,
            cancellationToken).ConfigureAwait(false);
        var metadata = await StageProvisioningArtifactAsync(
            release.PackageMetadataUri,
            release.PackageMetadataSha256,
            release.PackageMetadataSizeBytes,
            "package-metadata.json",
            releaseDirectory,
            cancellationToken).ConfigureAwait(false);

        return new WindowsStagedProvisioningBundle(
            package.PackagePath,
            bootstrap,
            installScript,
            uninstallScript,
            metadata,
            release);
    }

    private async Task<WindowsStagedPackage> DownloadAndStagePackageAsync(
        WindowsUpdateRelease release,
        string stagingRoot,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stagingRoot);
        var expectedSize = release.PackageSizeBytes;
        if (expectedSize is null or <= 0 ||
            expectedSize > WindowsUpdateConstants.MaxPackageBytes)
        {
            throw new InvalidOperationException(
                "Windows update package size is invalid.");
        }

        var packageUri = new Uri(release.PackageUri, UriKind.Absolute);
        if (!packageUri.AbsolutePath.EndsWith(
                ".msix",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Windows update package_uri must reference an .msix package.");
        }

        var releaseVersion = WindowsUpdateManifestVerifier.ParseVersion(
            release.Version,
            "release.version");
        var normalizedArchitecture =
            WindowsUpdateManifestVerifier.NormalizeArchitecture(
                release.Architecture);
        var releaseDirectory = Path.Combine(
            stagingRoot,
            normalizedArchitecture,
            releaseVersion.ToString());
        Directory.CreateDirectory(releaseDirectory);

        var fileName = Path.GetFileName(packageUri.LocalPath);
        if (string.IsNullOrWhiteSpace(fileName))
        {
            throw new InvalidOperationException(
                "Windows update package URI does not contain a file name.");
        }

        var finalPath = Path.Combine(releaseDirectory, fileName);
        if (File.Exists(finalPath))
        {
            var existingHash = await ComputeSha256Async(
                finalPath,
                cancellationToken);
            if (string.Equals(
                    existingHash,
                    release.PackageSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                return new WindowsStagedPackage(
                    finalPath,
                    existingHash,
                    release);
            }

            File.Delete(finalPath);
        }

        var tempPath = Path.Combine(
            releaseDirectory,
            $"{Guid.NewGuid():N}.partial");

        try
        {
            using var response = await _httpClient.GetAsync(
                packageUri,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is long contentLength &&
                contentLength != expectedSize)
            {
                throw new InvalidOperationException(
                    "Windows update package size did not match the signed manifest.");
            }

            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long totalBytes = 0;
            {
                await using var source = await response.Content.ReadAsStreamAsync(
                    cancellationToken);
                await using var destination = new FileStream(
                    tempPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    81920,
                    FileOptions.Asynchronous | FileOptions.SequentialScan);

                var buffer = new byte[81920];
                while (true)
                {
                    var read = await source.ReadAsync(
                        buffer.AsMemory(0, buffer.Length),
                        cancellationToken);
                    if (read == 0)
                    {
                        break;
                    }

                    totalBytes += read;
                    if (totalBytes > expectedSize)
                    {
                        throw new InvalidOperationException(
                            "Windows update package size did not match the signed manifest.");
                    }

                    hash.AppendData(buffer, 0, read);
                    await destination.WriteAsync(
                        buffer.AsMemory(0, read),
                        cancellationToken);
                }

                await destination.FlushAsync(cancellationToken);
            }
            if (totalBytes != expectedSize)
            {
                throw new InvalidOperationException(
                    "Windows update package size did not match the signed manifest.");
            }

            var actualHash = Convert.ToHexString(hash.GetHashAndReset());
            if (!string.Equals(
                    actualHash,
                    release.PackageSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Windows update package SHA-256 did not match the signed manifest.");
            }

            File.Move(tempPath, finalPath, overwrite: false);
            return new WindowsStagedPackage(
                finalPath,
                actualHash,
                release);
        }
        catch
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }

            throw;
        }
    }

    private async Task<string> StageProvisioningArtifactAsync(
        string? uriValue,
        string? expectedHash,
        long? expectedSize,
        string expectedFileName,
        string releaseDirectory,
        CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(uriValue, UriKind.Absolute, out var uri) ||
            !string.Equals(
                Path.GetFileName(uri.LocalPath),
                expectedFileName,
                StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(expectedHash) ||
            expectedHash.Length != 64 ||
            expectedSize is null or <= 0 ||
            expectedSize > WindowsUpdateConstants.MaxProvisioningArtifactBytes)
        {
            throw new InvalidOperationException(
                "Windows update provisioning artifact metadata is invalid.");
        }

        ValidateTrustedArtifactUri(uri);
        var finalPath = Path.Combine(releaseDirectory, expectedFileName);
        if (File.Exists(finalPath) &&
            string.Equals(
                await ComputeSha256Async(finalPath, cancellationToken)
                    .ConfigureAwait(false),
                expectedHash,
                StringComparison.OrdinalIgnoreCase))
        {
            return finalPath;
        }

        File.Delete(finalPath);
        var temporaryPath = Path.Combine(
            releaseDirectory,
            $"{Guid.NewGuid():N}.partial");
        try
        {
            using var response = await _httpClient.GetAsync(
                uri,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is long contentLength &&
                contentLength != expectedSize)
            {
                throw new InvalidOperationException(
                    "Windows update provisioning artifact size did not match the signed manifest.");
            }

            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long totalBytes = 0;
            await using (var source = await response.Content.ReadAsStreamAsync(
                             cancellationToken).ConfigureAwait(false))
            await using (var destination = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             81920,
                             FileOptions.Asynchronous |
                                FileOptions.SequentialScan))
            {
                var buffer = new byte[81920];
                while (true)
                {
                    var read = await source.ReadAsync(
                        buffer.AsMemory(),
                        cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    totalBytes += read;
                    if (totalBytes > expectedSize)
                    {
                        throw new InvalidOperationException(
                            "Windows update provisioning artifact size did not match the signed manifest.");
                    }

                    hash.AppendData(buffer, 0, read);
                    await destination.WriteAsync(
                        buffer.AsMemory(0, read),
                        cancellationToken).ConfigureAwait(false);
                }

                await destination.FlushAsync(cancellationToken)
                    .ConfigureAwait(false);
            }

            if (totalBytes != expectedSize ||
                !string.Equals(
                    Convert.ToHexString(hash.GetHashAndReset()),
                    expectedHash,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Windows update provisioning artifact did not match the signed manifest.");
            }

            File.Move(temporaryPath, finalPath, overwrite: false);
            return finalPath;
        }
        catch
        {
            File.Delete(temporaryPath);
            throw;
        }
    }

    private void ValidateTrustedArtifactUri(Uri uri)
    {
        var trusted = _options.TrustedOrigin;
        var trustedPath = trusted.AbsolutePath.TrimEnd('/');
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !string.Equals(
                uri.Host,
                trusted.Host,
                StringComparison.OrdinalIgnoreCase) ||
            uri.Port != trusted.Port ||
            uri.Query.Length > 0 ||
            uri.Fragment.Length > 0 ||
            trustedPath.Length > 0 &&
            !uri.AbsolutePath.StartsWith(
                trustedPath + "/",
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Windows update provisioning artifact is outside the pinned origin.");
        }
    }

    private static async Task<byte[]> ReadBoundedContentAsync(
        HttpContent content,
        int maximumBytes,
        string contentName,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is long contentLength &&
            contentLength > maximumBytes)
        {
            throw new InvalidOperationException(
                $"Windows update {contentName} exceeded the maximum allowed size.");
        }

        await using var source = await content.ReadAsStreamAsync(
            cancellationToken);
        using var destination = new MemoryStream(
            content.Headers.ContentLength is > 0 and <= int.MaxValue
                ? (int)content.Headers.ContentLength.Value
                : 0);
        var buffer = new byte[Math.Min(81920, maximumBytes + 1)];
        while (true)
        {
            var remaining = maximumBytes - checked((int)destination.Length);
            var read = await source.ReadAsync(
                buffer.AsMemory(0, Math.Min(buffer.Length, remaining + 1)),
                cancellationToken);
            if (read == 0)
            {
                return destination.ToArray();
            }

            if (destination.Length + read > maximumBytes)
            {
                throw new InvalidOperationException(
                    $"Windows update {contentName} exceeded the maximum allowed size.");
            }

            destination.Write(buffer, 0, read);
        }
    }

    private static async Task<string> ComputeSha256Async(
        string path,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            81920,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[81920];
        while (true)
        {
            var read = await stream.ReadAsync(
                buffer.AsMemory(0, buffer.Length),
                cancellationToken);
            if (read == 0)
            {
                break;
            }

            hash.AppendData(buffer, 0, read);
        }

        return Convert.ToHexString(hash.GetHashAndReset());
    }
}

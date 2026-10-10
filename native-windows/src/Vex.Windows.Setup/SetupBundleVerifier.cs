using System.Collections.ObjectModel;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;

namespace Vex.Windows.Setup;

internal sealed record SetupArtifact(string FileName, string Sha256, long SizeBytes);

internal sealed record SetupMetadata(
    string Channel,
    string Architecture,
    string Version,
    string PackageName,
    string Publisher,
    string CertificateSha256,
    SetupArtifact Package,
    SetupArtifact Bootstrap,
    SetupArtifact InstallServiceScript,
    SetupArtifact UninstallServiceScript,
    SetupArtifact VclibsDependency,
    string VclibsDependencyVersion);

/// <summary>The verified files remain locked until the bootstrap and its elevated child finish.</summary>
internal sealed class SetupBundle : IDisposable
{
    private readonly IReadOnlyList<FileStream> heldFiles;

    internal SetupBundle(SetupMetadata metadata, string directory, string setupPath,
        string metadataSha256, IReadOnlyList<FileStream> files)
    {
        Metadata = metadata;
        DirectoryPath = directory;
        SetupPath = setupPath;
        MetadataSha256 = metadataSha256;
        heldFiles = files;
        LockedPaths = new ReadOnlyCollection<string>(files.Select(file => file.Name).ToArray());
    }

    public SetupMetadata Metadata { get; }
    public string DirectoryPath { get; }
    public string SetupPath { get; }
    public string MetadataSha256 { get; }
    public string CertificateSha256 => Metadata.CertificateSha256;
    public string BootstrapSha256 => Metadata.Bootstrap.Sha256;
    public string Architecture => Metadata.Architecture;
    public string Version => Metadata.Version;
    public string MetadataPath => Path.Combine(DirectoryPath, "package-metadata.json");
    public string PackagePath => Path.Combine(DirectoryPath, Metadata.Package.FileName);
    public string BootstrapPath => Path.Combine(DirectoryPath, Metadata.Bootstrap.FileName);
    public string InstallServiceScriptPath => Path.Combine(DirectoryPath, Metadata.InstallServiceScript.FileName);
    public string UninstallServiceScriptPath => Path.Combine(DirectoryPath, Metadata.UninstallServiceScript.FileName);
    public string VclibsDependencyPath => Path.Combine(DirectoryPath, Metadata.VclibsDependency.FileName);
    public IReadOnlyList<string> LockedPaths { get; }

    public void Dispose()
    {
        foreach (var file in heldFiles) file.Dispose();
    }
}

internal static class SetupBundleVerifier
{
    internal const int MaximumMetadataBytes = 64 * 1024;
    internal const long MaximumPackageBytes = 512L * 1024 * 1024;
    internal const long MaximumScriptBytes = 1024 * 1024;
    internal const long MaximumVclibsBytes = 32L * 1024 * 1024;

    /// <summary>Only metadata embedded in the signed Setup executable provides release pins.</summary>
    public static SetupBundle Verify(byte[] embeddedMetadata, string bundleDirectory,
        string currentExecutablePath, Action<string, string> verifySignature)
    {
        ArgumentNullException.ThrowIfNull(embeddedMetadata);
        ArgumentNullException.ThrowIfNull(verifySignature);
        if (embeddedMetadata.Length is <= 0 or > MaximumMetadataBytes)
            throw Invalid("Embedded package metadata exceeds its size limit.");

        // Snapshot caller-owned bytes before deriving both the model and its immutable pin.
        var metadataBytes = embeddedMetadata.ToArray();
        var metadata = ReadMetadata(metadataBytes);
        var metadataSha256 = Convert.ToHexString(SHA256.HashData(metadataBytes));
        var directory = Path.GetFullPath(bundleDirectory);
        AssertRegularPath(directory, directoryExpected: true);
        var setupPath = Path.GetFullPath(currentExecutablePath);
        var heldFiles = new List<FileStream>();
        try
        {
            var externalMetadata = OpenLocked(Path.Combine(directory, "package-metadata.json"), heldFiles);
            VerifyFile(externalMetadata, metadataSha256, metadataBytes.LongLength, MaximumMetadataBytes);
            foreach (var artifact in Artifacts(metadata))
            {
                var file = OpenLocked(Path.Combine(directory, artifact.FileName), heldFiles);
                VerifyFile(file, artifact.Sha256, artifact.SizeBytes, LimitFor(artifact, metadata));
            }
            var setupFile = OpenLocked(setupPath, heldFiles);
            if (setupFile.Length is <= 0 or > MaximumPackageBytes)
                throw Invalid("The setup executable exceeds its size limit.");
            VerifyPackageIdentity(heldFiles.Single(file =>
                string.Equals(file.Name, Path.Combine(directory, metadata.Package.FileName), StringComparison.Ordinal)), metadata);

            // The Microsoft framework has its own publisher, checked by the pinned bootstrap.
            // Every first-party executable/script must have the embedded release certificate.
            verifySignature(setupPath, metadata.CertificateSha256);
            verifySignature(Path.Combine(directory, metadata.Package.FileName), metadata.CertificateSha256);
            verifySignature(Path.Combine(directory, metadata.Bootstrap.FileName), metadata.CertificateSha256);
            verifySignature(Path.Combine(directory, metadata.InstallServiceScript.FileName), metadata.CertificateSha256);
            verifySignature(Path.Combine(directory, metadata.UninstallServiceScript.FileName), metadata.CertificateSha256);
            return new SetupBundle(metadata, directory, setupPath, metadataSha256, heldFiles.ToArray());
        }
        catch
        {
            foreach (var file in heldFiles) file.Dispose();
            throw;
        }
    }

    private static SetupMetadata ReadMetadata(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw Invalid("Package metadata must be an object.");
        RejectDuplicateProperties(root);
        RequireText(root, "schema", "vex.windows-package-output.v2");
        var architecture = Text(root, "architecture");
        if (architecture is not ("x64" or "arm64")) throw Invalid("Package architecture is unsupported.");
        var channel = Text(root, "channel");
        if (!Regex.IsMatch(channel, "^[a-z][a-z0-9_-]{0,31}$", RegexOptions.CultureInvariant))
            throw Invalid("Package channel is invalid.");
        var version = FourPartVersion(root, "version");
        var packageName = Text(root, "package_name");
        if (!Regex.IsMatch(packageName, "^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$", RegexOptions.CultureInvariant))
            throw Invalid("Package identity is invalid.");
        var publisher = Text(root, "publisher");
        if (publisher.Length > 2048 || publisher.Any(char.IsControl))
            throw Invalid("Package publisher is invalid.");
        try { _ = new X500DistinguishedName(publisher); }
        catch (CryptographicException) { throw Invalid("Package publisher is not a valid distinguished name."); }
        RequireText(root, "install_entrypoint", "elevated_bootstrap");
        RequireText(root, "service_ownership", "manual_sc_bootstrap");
        RequireFalse(root, "raw_msix_provisions_service");
        RequireFalse(root, "raw_appinstaller_provisions_service");
        foreach (var name in new[] { "app_executable_sha256", "service_executable_sha256", "amneziawg_sha256",
                     "wintun_sha256", "profile_signing_keyring_sha256" }) Hash(root, name);
        return new SetupMetadata(channel, architecture, version, packageName, publisher,
            Hash(root, "client_certificate_sha256"),
            Artifact(root, "package", $"VEX.Native.{channel}.{architecture}.{version}.msix", MaximumPackageBytes),
            Artifact(root, "bootstrap", "bootstrap-native-windows.ps1", MaximumScriptBytes),
            Artifact(root, "install_service_script", "install-vpn-service.ps1", MaximumScriptBytes),
            Artifact(root, "uninstall_service_script", "uninstall-vpn-service.ps1", MaximumScriptBytes),
            Artifact(root, "vclibs_dependency", $"Microsoft.VCLibs.{architecture}.14.00.Desktop.appx", MaximumVclibsBytes),
            FourPartVersion(root, "vclibs_dependency_version"));
    }

    private static SetupArtifact Artifact(JsonElement root, string prefix, string expectedName, long maximum)
    {
        var name = Text(root, prefix + "_file");
        if (!string.Equals(name, expectedName, StringComparison.Ordinal))
            throw Invalid("Package metadata contains a noncanonical file name.");
        var sizeProperty = Required(root, prefix + "_size_bytes");
        if (sizeProperty.ValueKind != JsonValueKind.Number || !sizeProperty.TryGetInt64(out var size) ||
            size <= 0 || size > maximum) throw Invalid("An artifact exceeds its size limit.");
        return new SetupArtifact(name, Hash(root, prefix + "_sha256"), size);
    }

    private static IEnumerable<SetupArtifact> Artifacts(SetupMetadata metadata) =>
        [metadata.Package, metadata.Bootstrap, metadata.InstallServiceScript, metadata.UninstallServiceScript, metadata.VclibsDependency];

    private static long LimitFor(SetupArtifact artifact, SetupMetadata metadata) =>
        artifact == metadata.Package ? MaximumPackageBytes :
        artifact == metadata.VclibsDependency ? MaximumVclibsBytes : MaximumScriptBytes;

    private static FileStream OpenLocked(string path, List<FileStream> heldFiles)
    {
        AssertRegularPath(path, directoryExpected: false);
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            64 * 1024, FileOptions.SequentialScan);
        heldFiles.Add(file);
        AssertRegularPath(path, directoryExpected: false);
        return file;
    }

    private static void AssertRegularPath(string path, bool directoryExpected)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0 ||
            ((attributes & FileAttributes.Directory) != 0) != directoryExpected)
            throw Invalid("The setup bundle must contain regular files and directories.");
        for (var parent = Path.GetDirectoryName(path); !string.IsNullOrEmpty(parent); parent = Path.GetDirectoryName(parent))
        {
            if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0)
                throw Invalid("The setup bundle cannot use redirected directories.");
        }
    }

    private static void VerifyFile(FileStream file, string hash, long expectedLength, long maximum)
    {
        if (file.Length <= 0 || file.Length != expectedLength || file.Length > maximum)
            throw Invalid("An artifact length differs from the signed release.");
        file.Position = 0;
        var actual = Convert.ToHexString(SHA256.HashData(file));
        if (!string.Equals(actual, hash, StringComparison.OrdinalIgnoreCase) || file.Length != expectedLength)
            throw Invalid("An artifact hash differs from the signed release.");
        file.Position = 0;
    }

    private static void VerifyPackageIdentity(FileStream file, SetupMetadata metadata)
    {
        using var archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: true);
        var manifests = archive.Entries.Where(entry => string.Equals(entry.FullName, "AppxManifest.xml", StringComparison.OrdinalIgnoreCase)).ToArray();
        var signatures = archive.Entries.Where(entry => string.Equals(entry.FullName, "AppxSignature.p7x", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (manifests.Length != 1 || manifests[0].FullName != "AppxManifest.xml" ||
            manifests[0].Length is <= 0 or > 1024 * 1024 || signatures.Length != 1 ||
            signatures[0].FullName != "AppxSignature.p7x" || signatures[0].Length <= 0)
            throw Invalid("The MSIX manifest or signature is missing or ambiguous.");
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = 1024 * 1024,
            IgnoreComments = true
        };
        using var stream = manifests[0].Open();
        using var reader = XmlReader.Create(stream, settings);
        var manifest = new XmlDocument { XmlResolver = null };
        manifest.Load(reader);
        var identities = manifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Identity']");
        if (identities is null || identities.Count != 1 || identities[0] is not XmlElement identity ||
            identity.GetAttribute("Name") != metadata.PackageName || identity.GetAttribute("Publisher") != metadata.Publisher ||
            identity.GetAttribute("Version") != metadata.Version || identity.GetAttribute("ProcessorArchitecture") != metadata.Architecture)
            throw Invalid("The MSIX identity differs from the signed release.");
    }

    private static void RejectDuplicateProperties(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            // PowerShell's subsequent metadata consumer also treats names without case sensitivity.
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw Invalid("Package metadata contains duplicate properties.");
                RejectDuplicateProperties(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var item in value.EnumerateArray()) RejectDuplicateProperties(item);
    }

    private static JsonElement Required(JsonElement root, string name) =>
        root.TryGetProperty(name, out var property) ? property : throw Invalid("A required package metadata field is missing.");

    private static string Text(JsonElement root, string name)
    {
        var property = Required(root, name);
        if (property.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(property.GetString()))
            throw Invalid("A required package metadata string is invalid.");
        return property.GetString()!;
    }

    private static string Hash(JsonElement root, string name)
    {
        var hash = Text(root, name);
        if (!Regex.IsMatch(hash, "^[A-Fa-f0-9]{64}$", RegexOptions.CultureInvariant))
            throw Invalid("A release SHA-256 pin is invalid.");
        return hash.ToUpperInvariant();
    }

    private static string FourPartVersion(JsonElement root, string name)
    {
        var version = Text(root, name);
        var parts = version.Split('.');
        if (parts.Length != 4 || parts.Any(part => !ushort.TryParse(part, NumberStyles.None,
                CultureInfo.InvariantCulture, out var number) || number.ToString(CultureInfo.InvariantCulture) != part))
            throw Invalid("A package version must contain four canonical unsigned 16-bit components.");
        return version;
    }

    private static void RequireText(JsonElement root, string name, string expected)
    {
        if (!string.Equals(Text(root, name), expected, StringComparison.Ordinal))
            throw Invalid("The setup metadata declares an unsupported installation contract.");
    }

    private static void RequireFalse(JsonElement root, string name)
    {
        if (Required(root, name).ValueKind != JsonValueKind.False)
            throw Invalid("The setup metadata must declare bootstrap-owned service provisioning.");
    }

    private static InvalidDataException Invalid(string message) => new(message);
}

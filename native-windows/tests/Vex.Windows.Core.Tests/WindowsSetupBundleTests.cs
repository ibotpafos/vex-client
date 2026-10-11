using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml;
using Vex.Windows.Setup;

internal static class WindowsSetupBundleTests
{
    public static void Run()
    {
        foreach (var architecture in new[] { "x64", "arm64" })
        {
            using var fixture = new BundleFixture(architecture);
            var calls = new List<string>();
            using (var bundle = SetupBundleVerifier.Verify(fixture.Bytes, fixture.Root, fixture.SetupPath, (path, pin) =>
            {
                Require(pin == BundleFixture.Certificate, "Every first-party signature must use the embedded release certificate.");
                calls.Add(path);
            }))
            {
                Require(bundle.Architecture == architecture && bundle.Version == "1.2.3.4" &&
                        bundle.Metadata.PackageName == "VEX.Native" && bundle.Metadata.Publisher == "CN=VEX",
                    "Both official architectures must preserve the signed package identity.");
                Require(bundle.MetadataSha256 == Convert.ToHexString(SHA256.HashData(fixture.Bytes)) &&
                        bundle.BootstrapSha256 == fixture.Metadata["bootstrap_sha256"].ToString(),
                    "The launch plan must preserve the exact embedded metadata and bootstrap pins.");
                Require(bundle.LockedPaths.Count == 7 && bundle.LockedPaths.Distinct().Count() == 7 &&
                        bundle.LockedPaths.Contains(bundle.MetadataPath) && bundle.LockedPaths.Contains(bundle.VclibsDependencyPath),
                    "Metadata, every artifact and the setup executable must remain locked through installation.");
                Require(calls.SequenceEqual(new[] { fixture.SetupPath, bundle.PackagePath, bundle.BootstrapPath,
                        bundle.InstallServiceScriptPath, bundle.UninstallServiceScriptPath }),
                    "The setup executable, MSIX and all scripts must be signature-verified before returning a launch plan.");
                if (OperatingSystem.IsWindows())
                    RejectWrite(bundle.BootstrapPath, "A verified bootstrap must not be writable while the launch plan is alive.");
            }
            File.WriteAllText(fixture.PathFor("bootstrap_file"), "Released locks permit normal cleanup.");
        }

        using (var fixture = new BundleFixture())
        {
            File.AppendAllText(fixture.MetadataPath, " ");
            Reject(fixture, "External metadata whitespace changes must fail the exact embedded-byte hash pin.");
        }
        using (var fixture = new BundleFixture())
        {
            var path = fixture.PathFor("bootstrap_file");
            var bytes = File.ReadAllBytes(path);
            bytes[0] ^= 1;
            File.WriteAllBytes(path, bytes);
            Reject(fixture, "A same-length bootstrap mutation must fail its embedded hash pin.");
        }
        using (var fixture = new BundleFixture())
        {
            File.Delete(fixture.PathFor("install_service_script_file"));
            Reject(fixture, "A partial bundle must fail before signature callbacks or installation.");
        }
        using (var fixture = new BundleFixture())
        {
            File.AppendAllText(fixture.PathFor("vclibs_dependency_file"), "extra");
            Reject(fixture, "Actual framework size must match the embedded release size.");
        }

        foreach (var invalidFile in new[] { "../bootstrap-native-windows.ps1", "..\\bootstrap-native-windows.ps1",
                     "C:\\bootstrap-native-windows.ps1", "bootstrap-native-windows.ps1:payload", "other.ps1" })
            RejectMetadata("bootstrap_file", invalidFile, "Only the official direct bootstrap filename can be executed.");
        RejectMetadata("package_file", "other.msix", "The package filename must exactly match channel, architecture and version.");
        RejectMetadata("vclibs_dependency_file", "Microsoft.VCLibs.arm64.14.00.Desktop.appx", "The dependency must match the package architecture.");
        RejectMetadata("schema", "vex.windows-package-output.v1", "Unsupported metadata schemas must fail.");
        RejectMetadata("architecture", "x86", "Unsupported package architectures must fail.");
        RejectMetadata("channel", "../stable", "Release channels must satisfy the official naming contract.");
        RejectMetadata("package_name", "../VEX.Native", "Unsafe package identities must fail.");
        RejectMetadata("publisher", "CN=VEX\nCN=Other", "Publisher identities must be a single bounded string.");
        foreach (var version in new[] { "1.2.3", "1.2.3.65536", "1.2.03.4", "-1.2.3.4" })
            RejectMetadata("version", version, "Versions must contain four canonical unsigned 16-bit components.");
        RejectMetadata("install_entrypoint", "raw_msix", "Service installation must enter the elevated bootstrap.");
        RejectMetadata("service_ownership", "packaged_service", "Only manual bootstrap service ownership is supported.");
        RejectMetadata("raw_msix_provisions_service", true, "A raw MSIX must not claim to provision the VPN service.");
        RejectMetadata("raw_appinstaller_provisions_service", "false", "Service ownership flags must be JSON booleans.");
        RejectMetadata("client_certificate_sha256", "short", "The shipping certificate pin must be a complete SHA-256 value.");
        RejectMetadata("bootstrap_sha256", new string('G', 64), "Artifact hash pins must be hexadecimal.");
        RejectMetadata("service_executable_sha256", "", "Installed service identity pins are mandatory.");
        foreach (var (field, maximum) in new[]
        {
            ("package_size_bytes", SetupBundleVerifier.MaximumPackageBytes),
            ("bootstrap_size_bytes", SetupBundleVerifier.MaximumScriptBytes),
            ("install_service_script_size_bytes", SetupBundleVerifier.MaximumScriptBytes),
            ("uninstall_service_script_size_bytes", SetupBundleVerifier.MaximumScriptBytes),
            ("vclibs_dependency_size_bytes", SetupBundleVerifier.MaximumVclibsBytes)
        })
        {
            RejectMetadata(field, 0, "Every artifact size must be positive.");
            RejectMetadata(field, maximum + 1, "Every artifact must satisfy its independent size bound.");
            RejectMetadata(field, "12", "Artifact sizes cannot be strings.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.Metadata.Remove("uninstall_service_script_size_bytes");
            fixture.WriteMetadata();
            Reject(fixture, "Missing required size fields must fail before installation.");
        }
        foreach (var duplicateName in new[] { "schema", "SCHEMA" })
        {
            using var fixture = new BundleFixture();
            var json = Encoding.UTF8.GetString(fixture.Bytes);
            fixture.Bytes = Encoding.UTF8.GetBytes("{\"" + duplicateName + "\":\"vex.windows-package-output.v2\"," + json[1..]);
            File.WriteAllBytes(fixture.MetadataPath, fixture.Bytes);
            Reject(fixture, "Exact or case-insensitive duplicate metadata fields must fail.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.Bytes = new byte[SetupBundleVerifier.MaximumMetadataBytes + 1];
            Reject(fixture, "Embedded metadata must be rejected before parsing when larger than 64 KiB.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.Metadata["display_name"] = new string('a', SetupBundleVerifier.MaximumMetadataBytes);
            fixture.WriteMetadata();
            Reject(fixture, "A valid JSON document still must satisfy the metadata byte limit.");
        }

        foreach (var rejectedSignature in new[] { "self", "bootstrap", "package", "install", "uninstall" })
        {
            using var fixture = new BundleFixture();
            var target = rejectedSignature switch
            {
                "self" => fixture.SetupPath,
                "bootstrap" => fixture.PathFor("bootstrap_file"),
                "package" => fixture.PathFor("package_file"),
                "install" => fixture.PathFor("install_service_script_file"),
                _ => fixture.PathFor("uninstall_service_script_file")
            };
            var rejected = false;
            try
            {
                using var unused = SetupBundleVerifier.Verify(fixture.Bytes, fixture.Root, fixture.SetupPath, (path, _) =>
                {
                    if (path == target) throw new CryptographicException("Test signature rejected.");
                });
            }
            catch (CryptographicException) { rejected = true; }
            Require(rejected, "A failed first-party signature must never return a launch plan.");
            File.WriteAllText(fixture.PathFor("bootstrap_file"), "Failure must release every acquired lock.");
        }
        foreach (var (attribute, value) in new[] { ("Name", "Other.Native"), ("Publisher", "CN=Other"),
                     ("Version", "1.2.3.5"), ("ProcessorArchitecture", "arm64") })
        {
            using var fixture = new BundleFixture();
            fixture.WritePackage(attribute, value);
            fixture.WriteMetadata();
            Reject(fixture, "The actual MSIX identity must match embedded metadata even with a mocked valid signer.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.WritePackage(duplicateManifest: true);
            fixture.WriteMetadata();
            Reject(fixture, "An ambiguous duplicate MSIX manifest must fail before installation.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.WritePackage(manifestOverride: "<!DOCTYPE Package [<!ENTITY unsafe SYSTEM 'file:///not-read'>]>" +
                "<Package><Identity Name='&unsafe;'/></Package>");
            fixture.WriteMetadata();
            Reject(fixture, "MSIX identity parsing must reject DTDs and external entity resolution.");
        }
        using (var fixture = new BundleFixture())
        {
            fixture.WritePackage(manifestOverride: new string('a', 1024 * 1024 + 1));
            fixture.WriteMetadata();
            Reject(fixture, "The decompressed MSIX manifest must satisfy its independent 1 MiB limit.");
        }
    }

    private static void RejectMetadata(string field, object value, string message)
    {
        using var fixture = new BundleFixture();
        fixture.Metadata[field] = value;
        fixture.WriteMetadata();
        Reject(fixture, message);
    }

    private static void Reject(BundleFixture fixture, string message)
    {
        var rejected = false;
        var signatureCalls = 0;
        try
        {
            using var unused = SetupBundleVerifier.Verify(fixture.Bytes, fixture.Root, fixture.SetupPath,
                (_, _) => signatureCalls++);
        }
        catch (Exception error) when (error is InvalidDataException or JsonException or IOException or XmlException)
        {
            rejected = true;
        }
        Require(rejected && signatureCalls == 0, message);
    }

    private static void RejectWrite(string path, string message)
    {
        var rejected = false;
        try { using var unused = File.Open(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite); }
        catch (IOException) { rejected = true; }
        Require(rejected, message);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class BundleFixture : IDisposable
    {
        public const string Certificate = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "vex-setup-tests-" + Guid.NewGuid().ToString("N"));
        public string MetadataPath => Path.Combine(Root, "package-metadata.json");
        public string SetupPath => Path.Combine(Root, "VEX.Setup." + Metadata["architecture"] + ".exe");
        public Dictionary<string, object> Metadata { get; } = new(StringComparer.Ordinal);
        public byte[] Bytes { get; set; } = [];

        public BundleFixture(string architecture = "x64")
        {
            Directory.CreateDirectory(Root);
            Metadata["schema"] = "vex.windows-package-output.v2";
            Metadata["channel"] = "stable";
            Metadata["architecture"] = architecture;
            Metadata["version"] = "1.2.3.4";
            Metadata["package_name"] = "VEX.Native";
            Metadata["publisher"] = "CN=VEX";
            Metadata["install_entrypoint"] = "elevated_bootstrap";
            Metadata["service_ownership"] = "manual_sc_bootstrap";
            Metadata["raw_msix_provisions_service"] = false;
            Metadata["raw_appinstaller_provisions_service"] = false;
            foreach (var name in new[] { "client_certificate_sha256", "app_executable_sha256", "service_executable_sha256",
                         "amneziawg_sha256", "wintun_sha256", "profile_signing_keyring_sha256" }) Metadata[name] = Certificate;
            Metadata["package_file"] = $"VEX.Native.stable.{architecture}.1.2.3.4.msix";
            Metadata["vclibs_dependency_version"] = "14.0.33728.0";
            WritePackage();
            WriteArtifact("bootstrap", "bootstrap-native-windows.ps1");
            WriteArtifact("install_service_script", "install-vpn-service.ps1");
            WriteArtifact("uninstall_service_script", "uninstall-vpn-service.ps1");
            WriteArtifact("vclibs_dependency", $"Microsoft.VCLibs.{architecture}.14.00.Desktop.appx");
            File.WriteAllText(SetupPath, "Mock signed setup executable.");
            WriteMetadata();
        }

        public string PathFor(string field) => Path.Combine(Root, (string)Metadata[field]);

        public void WriteMetadata()
        {
            Bytes = JsonSerializer.SerializeToUtf8Bytes(Metadata);
            File.WriteAllBytes(MetadataPath, Bytes);
        }

        public void WritePackage(string? replacedAttribute = null, string? replacement = null,
            bool duplicateManifest = false, string? manifestOverride = null)
        {
            var attributes = new Dictionary<string, string>
            {
                ["Name"] = "VEX.Native", ["Publisher"] = "CN=VEX", ["Version"] = "1.2.3.4",
                ["ProcessorArchitecture"] = (string)Metadata["architecture"]
            };
            if (replacedAttribute is not null) attributes[replacedAttribute] = replacement!;
            var manifest = manifestOverride ?? "<Package><Identity " + string.Join(" ", attributes.Select(pair =>
                pair.Key + "=\"" + pair.Value + "\"")) + "/></Package>";
            var path = PathFor("package_file");
            using (var file = File.Create(path))
            using (var archive = new ZipArchive(file, ZipArchiveMode.Create))
            {
                using (var writer = new StreamWriter(archive.CreateEntry("AppxManifest.xml").Open(), new UTF8Encoding(false)))
                    writer.Write(manifest);
                using (var writer = new StreamWriter(archive.CreateEntry("AppxSignature.p7x").Open()))
                    writer.Write("Mock package signature.");
                if (duplicateManifest)
                {
                    using var writer = new StreamWriter(archive.CreateEntry("AppxManifest.xml").Open());
                    writer.Write(manifest);
                }
            }
            PinArtifact("package", path);
        }

        private void WriteArtifact(string prefix, string name)
        {
            Metadata[prefix + "_file"] = name;
            var path = Path.Combine(Root, name);
            File.WriteAllText(path, "Mock signed artifact: " + name);
            PinArtifact(prefix, path);
        }

        private void PinArtifact(string prefix, string path)
        {
            Metadata[prefix + "_sha256"] = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
            Metadata[prefix + "_size_bytes"] = new FileInfo(path).Length;
        }

        public void Dispose() => Directory.Delete(Root, recursive: true);
    }
}

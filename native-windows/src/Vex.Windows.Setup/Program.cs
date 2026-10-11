using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Vex.Windows.Setup;

internal static class Program
{
    internal const string MetadataResource = "Vex.Windows.Setup.ReleaseMetadata.json";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            if (args[0] != "--verify-bundle" ||
                (args.Length != 1 && (args.Length != 3 || args[1] != "--result-path"))) return 2;
            return VerifyCommand(args.Length == 3 ? args[2] : null);
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new SetupForm());
        return 0;
    }

    internal static byte[]? ReadEmbeddedMetadata()
    {
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(MetadataResource);
        if (resource is null) return null;
        if (resource.Length <= 0 || resource.Length > 64 * 1024) throw new InvalidDataException("Metadata size is invalid.");
        using var buffer = new MemoryStream();
        resource.CopyTo(buffer);
        return buffer.ToArray();
    }

    internal static SetupBundle VerifyBundle(CancellationToken cancellationToken = default)
    {
        var metadata = ReadEmbeddedMetadata() ?? throw new InvalidDataException("The review launcher has no release metadata.");
        // Environment.ProcessPath is the signed apphost, also for single-file
        // publishing; Assembly.Location may point at an extraction directory.
        var executable = Environment.ProcessPath ?? throw new InvalidDataException("Setup image cannot be identified.");
        var directory = Path.GetDirectoryName(executable) ?? throw new InvalidDataException("Setup directory cannot be identified.");
        WindowsPathGuard.AssertDirectory(directory);
        var bundle = SetupBundleVerifier.Verify(metadata, directory, executable,
            (path, certificate) => WindowsBootstrapLauncher.AssertSignature(path, certificate, cancellationToken));
        try
        {
            foreach (var path in bundle.LockedPaths) WindowsPathGuard.AssertFile(path);
            if (bundle.Architecture != RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant())
                throw new InvalidDataException("Setup architecture does not match the release.");
            return bundle;
        }
        catch { bundle.Dispose(); throw; }
    }

    private static int VerifyCommand(string? resultPath)
    {
        var evidence = new Dictionary<string, object?>
        {
            ["schema"] = "vex.windows-setup-verification.v1", ["passed"] = false,
            ["embedded_metadata_present"] = false, ["metadata_matches_embedded"] = false,
            ["bundle_hashes_verified"] = false, ["bootstrap_signature_verified"] = false,
            ["setup_signature_verified"] = false, ["architecture"] = null, ["version"] = null,
            ["failure_code"] = "verification_failed",
        };
        try
        {
            evidence["embedded_metadata_present"] = ReadEmbeddedMetadata() is not null;
            using var bundle = VerifyBundle();
            evidence["passed"] = true;
            foreach (var key in new[] { "metadata_matches_embedded", "bundle_hashes_verified", "bootstrap_signature_verified", "setup_signature_verified" }) evidence[key] = true;
            evidence["architecture"] = bundle.Architecture;
            evidence["version"] = bundle.Version;
            evidence["failure_code"] = null;
        }
        catch { /* No arbitrary exception, process or artifact content escapes. */ }
        try
        {
            var json = JsonSerializer.Serialize(evidence);
            if (resultPath is not null)
            {
                var destination = Path.GetFullPath(resultPath);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.WriteAllText(destination, json, new System.Text.UTF8Encoding(false));
            }
            else Console.WriteLine(json);
        }
        catch { return 4; }
        return (bool)evidence["passed"]! ? 0 : 3;
    }
}

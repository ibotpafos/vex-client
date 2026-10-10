using System.Security.Cryptography;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Updates;

internal static class WindowsReleasePolicyTests
{
    private static readonly Uri Origin = new("https://downloads.vexguard.app/windows/native/");
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");

    public static void Run()
    {
        using var signer = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var release = Release();
        var selected = Verify(signer, release, "0.0.0.0", "1.0.0.0", 5);
        var excluded = Verify(signer, release, "0.0.0.0", "1.0.0.0", 50);
        Require(selected.UpdateAvailable && selected.Release == release && !Snapshot(selected).Required,
            "An optional selected cohort must receive an optional target without a manufactured minimum.");
        Require(!excluded.UpdateAvailable && excluded.Reason == "rollout_not_selected" &&
            !Snapshot(excluded).Required,
            "Clients outside an optional cohort must remain usable and receive no target.");

        var belowFloor = Verify(signer, release, "1.5.0.0", "1.0.0.0", 99);
        Require(belowFloor.UpdateAvailable && belowFloor.Release == release && Snapshot(belowFloor).Required,
            "A client below the signed floor must receive an eligible target outside its cohort.");
        var satisfiedFloor = Verify(signer, release, "1.5.0.0", "1.5.0.0", 99);
        Require(!satisfiedFloor.UpdateAvailable && !Snapshot(satisfiedFloor).Required,
            "Satisfying the floor must retain the optional cohort rather than forcing every client.");

        var mandatory = Verify(signer, release with { Required = true, RolloutPercent = 0 },
            "0.0.0.0", "1.0.0.0", 99);
        Require(mandatory.UpdateAvailable && mandatory.RollbackState.RequiredTargetVersion == release.Version &&
            Snapshot(mandatory).Required,
            "A signed mandatory target must bypass even a legacy zero-percent cohort and persist its requirement.");
        var previousTarget = new WindowsUpdateRollbackState(1, "0.0.0.0", "2.0.0.0");
        var retry = Verify(signer, release, "0.0.0.0", "1.0.0.0", 99, previousTarget);
        Require(retry.UpdateAvailable && retry.Release == release && Snapshot(retry).Required,
            "A persisted required target must remain obtainable after later optional cohort metadata.");
        var unusable = Verify(signer, release, "3.0.0.0", "1.0.0.0", 0);
        Require(!unusable.UpdateAvailable && unusable.Release is null &&
            unusable.RollbackState.RequiredVersionFloor == "3.0.0.0" && Snapshot(unusable).Required,
            "A valid stronger signed floor must stay blocked without offering a package below that floor.");
        var belowPreviousTarget = Verify(signer, release, "0.0.0.0", "1.0.0.0", 0,
            previousTarget with { RequiredTargetVersion = "3.0.0.0" });
        Require(!belowPreviousTarget.UpdateAvailable && belowPreviousTarget.Release is null &&
            belowPreviousTarget.RollbackState.RequiredTargetVersion == "3.0.0.0",
            "A previously required target must not be replaced with an unusable older package.");

        // Legacy all-null dependency descriptors remain readable. New complete
        // descriptors must be pinned, bounded and architecture-specific.
        var dependency = release with
        {
            VclibsDependencyUri = Origin + "stable/2.0.0.0/x64/Microsoft.VCLibs.x64.14.00.Desktop.appx",
            VclibsDependencySha256 = new string('A', 64),
            VclibsDependencySizeBytes = 6L * 1024 * 1024,
        };
        Require(Verify(signer, dependency, "0.0.0.0", "1.0.0.0", 0).UpdateAvailable,
            "A complete trusted framework descriptor larger than script limits must be accepted.");
        foreach (var malformed in new[]
        {
            dependency with { VclibsDependencyUri = null },
            dependency with { VclibsDependencySha256 = null },
            dependency with { VclibsDependencySizeBytes = null },
            dependency with { VclibsDependencySha256 = new string('G', 64) },
            dependency with { VclibsDependencySizeBytes = 0 },
            dependency with { VclibsDependencySizeBytes = WindowsUpdateConstants.MaxDependencyBytes + 1 },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("https:", "http:", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("downloads.vexguard.app", "other.example", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("/windows/native/", "/other/", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri + "?unsigned=value" },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri + "#fragment" },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("https://", "https://user@", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("Microsoft.VCLibs.x64", "Microsoft.VCLibs.arm64", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace(".appx", ".msix", StringComparison.Ordinal) },
            dependency with { VclibsDependencyUri = dependency.VclibsDependencyUri!.Replace("Microsoft.VCLibs.x64.14.00.Desktop", "arbitrary", StringComparison.Ordinal) },
        }) Reject(() => Verify(signer, malformed, "0.0.0.0", "1.0.0.0", 0));
        var arm64 = dependency with
        {
            Architecture = "arm64",
            VclibsDependencyUri = Origin + "stable/2.0.0.0/arm64/Microsoft.VCLibs.arm64.14.00.Desktop.appx",
        };
        Require(Verify(signer, arm64, "0.0.0.0", "1.0.0.0", 0, architecture: "arm64").UpdateAvailable,
            "The matching ARM64 dependency filename must be accepted.");
    }

    private static WindowsUpdateRelease Release() => new(
        "2.0.0.0", "x64", "msix", Origin + "stable/2.0.0.0/x64/VEX.Native.msix",
        new string('A', 64), "VEX.Native.Windows", "CN=VEX", null, 1024, null,
        "Optional update", false, 10,
        InstallEntrypoint: "elevated_bootstrap", ServiceOwnership: "manual_sc_bootstrap",
        RawMsixProvisionsService: false, RawAppinstallerProvisionsService: false,
        BootstrapUri: Origin + "stable/2.0.0.0/x64/bootstrap-native-windows.ps1",
        BootstrapSha256: new string('A', 64), BootstrapSizeBytes: 32,
        InstallServiceScriptUri: Origin + "stable/2.0.0.0/x64/install-vpn-service.ps1",
        InstallServiceScriptSha256: new string('A', 64), InstallServiceScriptSizeBytes: 32,
        UninstallServiceScriptUri: Origin + "stable/2.0.0.0/x64/uninstall-vpn-service.ps1",
        UninstallServiceScriptSha256: new string('A', 64), UninstallServiceScriptSizeBytes: 32,
        PackageMetadataUri: Origin + "stable/2.0.0.0/x64/package-metadata.json",
        PackageMetadataSha256: new string('A', 64), PackageMetadataSizeBytes: 32);

    private static WindowsUpdateAssessment Verify(ECDsa signer, WindowsUpdateRelease release,
        string floor, string currentVersion, int bucket, WindowsUpdateRollbackState? previous = null,
        string architecture = "x64")
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new WindowsUpdateManifest(
            WindowsUpdateConstants.ManifestSchema, "stable", Now.ToString("O"), 2, floor,
            new("readiness-p256", WindowsUpdateConstants.SupportedAlgorithm), [release]),
            new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower });
        var signature = signer.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        return WindowsUpdateManifestVerifier.Verify(payload, Convert.ToBase64String(signature),
            new WindowsUpdateVerificationOptions(Origin, "stable", architecture, currentVersion,
                new WindowsUpdateKeyring(WindowsUpdateConstants.KeyringSchema,
                    [new("readiness-p256", WindowsUpdateConstants.SupportedAlgorithm,
                        Convert.ToBase64String(signer.ExportSubjectPublicKeyInfo()))]),
                bucket, previous, () => Now));
    }

    private static NativeUpdateSnapshot Snapshot(WindowsUpdateAssessment assessment) =>
        (assessment.Release is { } release
            ? NativeUpdateSnapshot.Available(assessment.CurrentVersion, release, "stable", "x64", release.Required)
            : NativeUpdateSnapshot.NoUpdate(assessment.CurrentVersion, "stable", "x64", assessment.Reason))
            .WithRollbackState(assessment.RollbackState);

    private static void Reject(Action action)
    {
        var rejected = false;
        try { action(); } catch (InvalidOperationException) { rejected = true; }
        Require(rejected, "Malformed or partial framework descriptors must be rejected before staging.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

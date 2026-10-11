using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Updates;

internal static class NativeUpdateServiceTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await InstallerLaunchPreservesRequiredReleaseAndRetryAsync();
        await FailedLauncherPreservesRequiredReleaseAsync();
        await VerifiedOptionalMetadataCannotClearUnsatisfiedRequirementAsync();
        await QueuedLaunchUsesNewerVerifiedReleaseAsync();
        await QueuedLaunchCannotBypassRollbackPersistenceFailureAsync();
        await PersistedRequiredFloorSurvivesRestartAndOfflineChecksAsync();
        await VerifiedMandatoryTargetAboveSignedFloorSurvivesRestartAsync();
        await DurableTargetAdvancesOnlyForVerifiedMandatoryReleasesAsync();
        await PersistedRequiredFloorRejectsAnOlderInstallTargetAsync();
        await AdvancingFloorCannotRetainAnOlderInstallTargetAsync();
        await InvalidSignaturePreservesKnownRequiredStateAsync();
        await DependencyMismatchPreventsLaunchAndAllowsVerifiedRetryAsync();
        await LargeDependencyStagesBeforeBootstrapAsync();
        foreach (var body in new[] { "manifest", "signature" })
        {
            await BodyDeadlineReleasesServiceGateAndAllowsRetryAsync(body);
            await CallerCancellationReleasesServiceGateAsync(body);
        }
        foreach (var artifact in new[]
        {
            "VEX.Native.msix", "bootstrap-native-windows.ps1", "install-vpn-service.ps1",
            "uninstall-vpn-service.ps1", "package-metadata.json",
            "Microsoft.VCLibs.x64.14.00.Desktop.appx",
        })
        {
            await ArtifactDeadlineReleasesServiceGateAndAllowsRetryAsync(artifact);
            await ArtifactCallerCancellationReleasesServiceGateAsync(artifact);
        }
    }

    private static async Task InstallerLaunchPreservesRequiredReleaseAndRetryAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true);
        var available = await fixture.Service.RefreshAsync(CancellationToken.None);
        var launched = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(launched.State == "installer_launched" && launched.Required && launched.UpdateAvailable &&
            launched.Release == available.Release && launched.Release?.BootstrapSha256 is { Length: 64 } &&
            launched.Release.PackageUri.StartsWith("https://", StringComparison.Ordinal),
            "Starting a bootstrap must retain the exact signed required release until installation is verified.");
        var retry = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(retry.Required && retry.Release == available.Release && fixture.Launched.Count == 2 &&
            fixture.Launched.All(bundle => bundle.Release == available.Release),
            "A cancelled or failed external installer must remain blocked and retry the original verified provisioning bundle.");
        Check(fixture.Launched.All(bundle => bundle.VclibsDependencyPath is not null &&
            File.Exists(bundle.VclibsDependencyPath)),
            "The bootstrap must receive its verified framework beside the signed release artifacts.");
    }

    private static async Task DependencyMismatchPreventsLaunchAndAllowsVerifiedRetryAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.CorruptDependency = true;
        var failed = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(failed.Required && failed.State == "required_update_error" && fixture.Launched.Count == 0 &&
            !Directory.EnumerateFiles(fixture.StagingRoot, "*.partial", SearchOption.AllDirectories).Any(),
            "A dependency whose bytes differ from the signed manifest cannot reach the bootstrap or clear required state.");
        fixture.CorruptDependency = false;
        var retry = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(retry.State == "installer_launched" && fixture.Launched.Single().VclibsDependencyPath is not null,
            "Corrected dependency bytes must permit a fresh verified retry.");
    }

    private static async Task LargeDependencyStagesBeforeBootstrapAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: false, largeDependency: true);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        var launched = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(launched.State == "installer_launched" &&
            new FileInfo(fixture.Launched.Single().VclibsDependencyPath!).Length >
                WindowsUpdateConstants.MaxProvisioningArtifactBytes,
            "A real-sized framework uses the dependency bound rather than the small helper-script limit.");
    }

    private static async Task FailedLauncherPreservesRequiredReleaseAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true);
        var available = await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.LaunchFailure = new IOException("Bootstrap process could not start.");
        var failed = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(failed.State == "required_update_error" && failed.Required && failed.Release == available.Release,
            "A launcher failure must preserve the mandatory update and original release metadata.");
    }

    private static async Task VerifiedOptionalMetadataCannotClearUnsatisfiedRequirementAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        fixture.Publish("3.0.0.0", required: false, revision: 2);
        var newer = await fixture.Service.RefreshAsync(CancellationToken.None);
        Check(newer.Required && newer.Release?.Version == "3.0.0.0",
            "A later optional release may replace the install target but cannot unlock the older running binary.");
        var installed = fixture.NewService("3.0.0.0", newer);
        var current = await installed.RefreshAsync(CancellationToken.None);
        Check(!current.Required && !current.UpdateAvailable && current.State == "current",
            "Only a signed assessment of a sufficiently new running version can clear the mandatory update.");
    }

    private static async Task QueuedLaunchUsesNewerVerifiedReleaseAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: false);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.Publish("3.0.0.0", required: true, revision: 2);
        var entered = Signal();
        var release = Signal();
        fixture.BeforeManifest = async token =>
        {
            entered.TrySetResult();
            await release.Task.WaitAsync(token);
        };
        var checking = fixture.Service.RefreshAsync(CancellationToken.None);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var launching = fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(!launching.IsCompleted, "Launch must wait behind the real service check gate.");
        release.SetResult();
        await checking;
        var launched = await launching;
        Check(launched.Required && fixture.Launched.Single().Release.Version == "3.0.0.0" &&
            fixture.ArtifactRequests.All(path => path.Contains("/3.0.0.0/", StringComparison.Ordinal)),
            "A launch queued behind a signed newer mandatory assessment must stage that assessment, never the stale optional snapshot.");
    }

    private static async Task QueuedLaunchCannotBypassRollbackPersistenceFailureAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: false);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.Publish("3.0.0.0", required: true, revision: 2);
        var entered = Signal();
        var release = Signal();
        fixture.BeforeManifest = async token =>
        {
            entered.TrySetResult();
            await release.Task.WaitAsync(token);
        };
        var checking = fixture.Service.RefreshAsync(CancellationToken.None);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var launching = fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        fixture.PersistenceFailure = true;
        release.SetResult();
        await checking;
        var failed = await launching;
        Check(failed.Required && failed.State == "required_update_error" && fixture.Launched.Count == 0 &&
            fixture.ArtifactRequests.Count == 0 && fixture.PersistenceAttempts >= 3,
            "A queued launch must re-check failed rollback persistence under the gate and cannot download or launch until it is durable.");
    }

    private static async Task PersistedRequiredFloorSurvivesRestartAndOfflineChecksAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true, floor: "2.0.0.0");
        await fixture.Service.RefreshAsync(CancellationToken.None);
        var restarted = fixture.NewService("1.0.0.0");
        Check(restarted.CurrentSnapshot.Required && restarted.CurrentSnapshot.UpdateAvailable &&
            restarted.CurrentSnapshot.Release is null,
            "The durable signed floor must block an old client before its startup network check.");
        fixture.Offline = true;
        var failed = await restarted.RefreshAsync(CancellationToken.None);
        var attempted = await restarted.PrepareAndLaunchAsync(CancellationToken.None);
        Check(failed.Required && attempted.Required && attempted.Release is null && fixture.Launched.Count == 0 &&
            attempted.RequiredVersionFloor == "2.0.0.0",
            "Offline startup and manual retry must retain the known mandatory floor without manufacturing an install target.");
        fixture.Offline = false;
        var retry = await restarted.RefreshAsync(CancellationToken.None);
        Check(retry.Required && retry.Release?.Version == "2.0.0.0",
            "Restored network must recover the signed target while preserving the required gate.");
        var upgraded = fixture.NewService("2.0.0.0");
        var satisfied = await upgraded.RefreshAsync(CancellationToken.None);
        Check(!satisfied.Required && !satisfied.UpdateAvailable,
            "The installed version satisfying the durable floor must remain usable after a verified check.");
    }

    private static async Task PersistedRequiredFloorRejectsAnOlderInstallTargetAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("3.0.0.0", required: true, floor: "3.0.0.0");
        await fixture.Service.RefreshAsync(CancellationToken.None);
        var restarted = fixture.NewService("1.0.0.0");
        fixture.Publish("2.0.0.0", required: false, revision: 2, floor: "3.0.0.0");
        var attempted = await restarted.PrepareAndLaunchAsync(CancellationToken.None);
        Check(attempted.Required && attempted.Release is null && fixture.Launched.Count == 0 &&
            fixture.ArtifactRequests.Count == 0,
            "A signed target below the persisted required floor cannot be installed to bypass the mandatory version.");
    }

    private static async Task VerifiedMandatoryTargetAboveSignedFloorSurvivesRestartAsync()
    {
        var legacy = JsonSerializer.Deserialize<WindowsUpdateRollbackState>(
            "{\"HighestManifestRevision\":1,\"RequiredVersionFloor\":\"1.0.0.0\"}");
        Check(legacy is { RequiredTargetVersion: null, RequiredVersionFloor: "1.0.0.0" },
            "Existing durable rollback records must remain readable without a required-target field.");
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true, floor: "1.0.0.0");
        await fixture.Service.RefreshAsync(CancellationToken.None);
        Check(fixture.StoredRollback?.RequiredVersionFloor == "1.0.0.0" &&
            fixture.StoredRollback.RequiredTargetVersion == "2.0.0.0",
            "A verified required release must durably record its target without rewriting the signed server floor.");
        var restarted = fixture.NewService("1.0.0.0");
        Check(restarted.CurrentSnapshot.Required && restarted.CurrentSnapshot.UpdateAvailable &&
            restarted.CurrentSnapshot.Release is null && restarted.CurrentSnapshot.RequiredVersionFloor == "1.0.0.0" &&
            restarted.CurrentSnapshot.RequiredTargetVersion == "2.0.0.0",
            "The recorded mandatory target must block an old binary even when it satisfies the signed floor.");
        fixture.Offline = true;
        var failed = await restarted.RefreshAsync(CancellationToken.None);
        var attempted = await restarted.PrepareAndLaunchAsync(CancellationToken.None);
        Check(failed.Required && attempted.Required && attempted.RequiredTargetVersion == "2.0.0.0" &&
            fixture.Launched.Count == 0,
            "Offline startup cannot forget the verified mandatory target or manufacture a download target.");
        fixture.Offline = false;
        var installed = fixture.NewService("2.0.0.0");
        var satisfied = await installed.RefreshAsync(CancellationToken.None);
        Check(!satisfied.Required && !satisfied.UpdateAvailable &&
            fixture.StoredRollback?.RequiredTargetVersion == "2.0.0.0" && fixture.StoredRollback.RequiredVersionFloor == "1.0.0.0",
            "The effective block must clear when the installed version satisfies the target, without erasing monotonic durable evidence.");
    }

    private static async Task DurableTargetAdvancesOnlyForVerifiedMandatoryReleasesAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.Publish("3.0.0.0", required: true, revision: 2);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        Check(fixture.StoredRollback?.RequiredTargetVersion == "3.0.0.0" &&
            fixture.StoredRollback.RequiredVersionFloor == "1.0.0.0",
            "A newer admitted mandatory release must advance the separate durable target only.");
        fixture.Publish("4.0.0.0", required: true, revision: 3);
        fixture.BadSignature = true;
        await fixture.Service.RefreshAsync(CancellationToken.None);
        Check(fixture.StoredRollback?.RequiredTargetVersion == "3.0.0.0" && fixture.StoredRollback.HighestManifestRevision == 2,
            "An invalid signature cannot advance the mandatory target or rollback revision.");
        fixture.BadSignature = false;
        fixture.Publish("5.0.0.0", required: false, revision: 3);
        await fixture.Service.RefreshAsync(CancellationToken.None);
        var restarted = fixture.NewService("1.0.0.0");
        Check(fixture.StoredRollback?.RequiredTargetVersion == "3.0.0.0" &&
            fixture.StoredRollback.RequiredVersionFloor == "1.0.0.0" && restarted.CurrentSnapshot.Required,
            "A newer optional release must preserve the last mandatory target without making its own version mandatory.");
    }

    private static async Task InvalidSignaturePreservesKnownRequiredStateAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true, floor: "2.0.0.0");
        var required = await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.BadSignature = true;
        var failed = await fixture.Service.RefreshAsync(CancellationToken.None);
        Check(failed.Required && failed.Release == required.Release && fixture.StoredRollback?.HighestManifestRevision == 1,
            "An invalid manifest signature must neither clear known mandatory state nor advance persisted rollback evidence.");
    }

    private static async Task AdvancingFloorCannotRetainAnOlderInstallTargetAsync()
    {
        using var fixture = new Fixture();
        fixture.Publish("2.0.0.0", required: true, floor: "2.0.0.0");
        await fixture.Service.RefreshAsync(CancellationToken.None);
        fixture.Publish("2.0.0.0", required: true, revision: 2, floor: "3.0.0.0");
        var advanced = await fixture.Service.RefreshAsync(CancellationToken.None);
        var attempted = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        Check(advanced.RequiredVersionFloor == "3.0.0.0" && advanced.Release is null && attempted.Required &&
            fixture.StoredRollback?.RequiredVersionFloor == "3.0.0.0" && fixture.Launched.Count == 0,
            "A newer verified floor must supersede the earlier mandatory target and prevent staging authority below that floor.");
    }

    private static async Task BodyDeadlineReleasesServiceGateAndAllowsRetryAsync(string body)
    {
        using var fixture = new Fixture(TimeSpan.FromMilliseconds(120));
        fixture.Http.Timeout = TimeSpan.FromMilliseconds(25);
        using var stalled = new StalledStream();
        fixture.StalledBody = body;
        fixture.Body = stalled;
        var check = fixture.Service.RefreshAsync(CancellationToken.None);
        await stalled.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var failed = await check.WaitAsync(TimeSpan.FromSeconds(2));
        Check(failed.State == "error" && stalled.Cancelled && fixture.StoredRollback is null,
            "The complete " + body + " body read must time out after headers and release the service gate without admitting unsigned metadata.");
        fixture.StalledBody = null;
        var retried = await fixture.Service.RefreshAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2));
        Check(retried.State == "available" && fixture.StoredRollback is not null,
            "A timed-out body must leave the actual service able to retry and verify the next signed response.");
    }

    private static async Task CallerCancellationReleasesServiceGateAsync(string body)
    {
        using var fixture = new Fixture(TimeSpan.FromSeconds(5));
        using var stalled = new StalledStream();
        using var cancellation = new CancellationTokenSource();
        fixture.StalledBody = body;
        fixture.Body = stalled;
        var check = fixture.Service.RefreshAsync(cancellation.Token);
        await stalled.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        try
        {
            await check.WaitAsync(TimeSpan.FromSeconds(2));
            throw new InvalidOperationException("Caller cancellation was swallowed as an updater error.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        Check(stalled.Cancelled && fixture.StoredRollback is null && fixture.Service.CurrentSnapshot.State == "configured",
            "Cancellation must preserve the previous state and admit no incomplete manifest.");
        fixture.StalledBody = null;
        Check((await fixture.Service.RefreshAsync(CancellationToken.None)).State == "available",
            "Caller cancellation must release the real operation gate for a later check.");
    }

    private static async Task ArtifactDeadlineReleasesServiceGateAndAllowsRetryAsync(string artifact)
    {
        using var fixture = new Fixture(artifactTimeout: TimeSpan.FromSeconds(1));
        fixture.Publish("2.0.0.0", required: true);
        fixture.Http.Timeout = TimeSpan.FromMilliseconds(25);
        var required = await fixture.Service.RefreshAsync(CancellationToken.None);
        using var stalled = new StalledStream();
        fixture.StalledBody = artifact;
        fixture.Body = stalled;
        var launch = fixture.Service.PrepareAndLaunchAsync(CancellationToken.None);
        await stalled.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var failed = await launch.WaitAsync(TimeSpan.FromSeconds(2));
        Check(failed.State == "required_update_error" && failed.Required &&
            failed.Release == required.Release && failed.StagedPackagePath is null && stalled.Cancelled &&
            fixture.Launched.Count == 0 && fixture.StoredRollback?.RequiredTargetVersion == "2.0.0.0",
            "A stalled " + artifact + " body must time out without launching or clearing the durable mandatory target.");
        Check(!Directory.EnumerateFiles(fixture.StagingRoot, "*.partial", SearchOption.AllDirectories).Any(),
            "A timed-out artifact body must remove its partial staging file.");
        Check((await fixture.Service.RefreshAsync(CancellationToken.None)
                .WaitAsync(TimeSpan.FromSeconds(2))).Required,
            "A timed-out artifact must release the service gate for the next check.");
        fixture.StalledBody = null;
        var retried = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(2));
        Check(retried.State == "installer_launched" && retried.Required && fixture.Launched.Count == 1,
            "The same verified provisioning bundle must remain installable after an artifact timeout.");
    }

    private static async Task ArtifactCallerCancellationReleasesServiceGateAsync(string artifact)
    {
        using var fixture = new Fixture(artifactTimeout: TimeSpan.FromSeconds(5));
        fixture.Publish("2.0.0.0", required: true);
        var required = await fixture.Service.RefreshAsync(CancellationToken.None);
        using var stalled = new StalledStream();
        using var cancellation = new CancellationTokenSource();
        fixture.StalledBody = artifact;
        fixture.Body = stalled;
        var launch = fixture.Service.PrepareAndLaunchAsync(cancellation.Token);
        await stalled.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        try
        {
            await launch.WaitAsync(TimeSpan.FromSeconds(2));
            throw new InvalidOperationException("Artifact caller cancellation was swallowed as an updater error.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        Check(stalled.Cancelled && fixture.Launched.Count == 0 &&
            fixture.Service.CurrentSnapshot == required &&
            !Directory.EnumerateFiles(fixture.StagingRoot, "*.partial", SearchOption.AllDirectories).Any(),
            "Cancelling a " + artifact + " body must preserve the exact required snapshot and clean partial staging.");
        fixture.StalledBody = null;
        var retried = await fixture.Service.PrepareAndLaunchAsync(CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(2));
        Check(retried.State == "installer_launched" && fixture.Launched.Count == 1,
            "Caller cancellation must release the operation gate and permit a verified retry.");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        private readonly DateTimeOffset _now = DateTimeOffset.UtcNow;
        private readonly TimeSpan? _timeout;
        private readonly TimeSpan? _artifactTimeout;
        private readonly string _directory = Path.Combine(Path.GetTempPath(), "vex-native-update-" + Guid.NewGuid().ToString("N"));
        private readonly Dictionary<string, byte[]> _artifacts = new(StringComparer.Ordinal);
        private byte[] _manifest = [];
        private string _signature = string.Empty;
        public NativeUpdateService Service { get; }
        public HttpClient Http { get; }
        public WindowsUpdateRollbackState? StoredRollback { get; private set; }
        public bool PersistenceFailure { get; set; }
        public int PersistenceAttempts { get; private set; }
        public bool Offline { get; set; }
        public bool BadSignature { get; set; }
        public string? StalledBody { get; set; }
        public StalledStream? Body { get; set; }
        public Func<CancellationToken, Task>? BeforeManifest { get; set; }
        public Exception? LaunchFailure { get; set; }
        public bool CorruptDependency { get; set; }
        public List<WindowsStagedProvisioningBundle> Launched { get; } = [];
        public List<string> ArtifactRequests { get; } = [];
        public string StagingRoot => _directory;

        public Fixture(TimeSpan? timeout = null, TimeSpan? artifactTimeout = null)
        {
            _timeout = timeout;
            _artifactTimeout = artifactTimeout;
            Http = new HttpClient(new Handler(this)) { Timeout = Timeout.InfiniteTimeSpan };
            Publish("2.0.0.0", required: false);
            Service = NewService("1.0.0.0");
        }

        public NativeUpdateService NewService(string currentVersion, NativeUpdateSnapshot? initial = null)
        {
            var options = new WindowsUpdateVerificationOptions(new Uri("https://updates.example.test/windows/"),
                "stable", "x64", currentVersion,
                new WindowsUpdateKeyring(WindowsUpdateConstants.KeyringSchema,
                    [new("test-update-key", WindowsUpdateConstants.SupportedAlgorithm,
                        Convert.ToBase64String(_key.ExportSubjectPublicKeyInfo()))]),
                RollbackState: StoredRollback, UtcNow: () => _now);
            var coordinator = new WindowsUpdateCoordinator(Http, options,
                new Uri("https://updates.example.test/windows/stable/x64/update.json"),
                new Uri("https://updates.example.test/windows/stable/x64/update.json.sig"), _timeout, _artifactTimeout);
            return new NativeUpdateService(coordinator,
                initial ?? NativeUpdateSnapshot.Configured(currentVersion, "stable", "x64"), _directory,
                state =>
                {
                    PersistenceAttempts++;
                    if (PersistenceFailure) throw new IOException("Protected rollback state is read-only.");
                    StoredRollback = JsonSerializer.Deserialize<WindowsUpdateRollbackState>(JsonSerializer.Serialize(state));
                }, bundle =>
                {
                    if (LaunchFailure is not null) throw LaunchFailure;
                    Launched.Add(bundle);
                }, StoredRollback);
        }

        public void Publish(string version, bool required, long revision = 1, string floor = "1.0.0.0",
            bool largeDependency = false)
        {
            string UriFor(string name) => "https://updates.example.test/windows/stable/" + version + "/x64/" + name;
            (string Uri, string Hash, int Size) Artifact(string name)
            {
                var bytes = Encoding.UTF8.GetBytes(version + ":" + name);
                var uri = UriFor(name);
                _artifacts[new Uri(uri).AbsolutePath] = bytes;
                return (uri, Convert.ToHexString(SHA256.HashData(bytes)), bytes.Length);
            }
            var package = Artifact("VEX.Native.msix");
            var bootstrap = Artifact("bootstrap-native-windows.ps1");
            var install = Artifact("install-vpn-service.ps1");
            var uninstall = Artifact("uninstall-vpn-service.ps1");
            var metadata = Artifact("package-metadata.json");
            var dependency = Artifact("Microsoft.VCLibs.x64.14.00.Desktop.appx");
            if (largeDependency)
            {
                var bytes = new byte[WindowsUpdateConstants.MaxProvisioningArtifactBytes + 1];
                RandomNumberGenerator.Fill(bytes);
                _artifacts[new Uri(dependency.Uri).AbsolutePath] = bytes;
                dependency = (dependency.Uri, Convert.ToHexString(SHA256.HashData(bytes)), bytes.Length);
            }
            var release = new WindowsUpdateRelease(version, "x64", "msix", package.Uri, package.Hash,
                "VEX.Native.Windows", "CN=VEX", null, package.Size, "1.0.0.0", "test release", required, 100,
                "elevated_bootstrap", "manual_sc_bootstrap", false, false,
                bootstrap.Uri, bootstrap.Hash, bootstrap.Size, install.Uri, install.Hash, install.Size,
                uninstall.Uri, uninstall.Hash, uninstall.Size, metadata.Uri, metadata.Hash, metadata.Size,
                dependency.Uri, dependency.Hash, dependency.Size);
            var manifest = new WindowsUpdateManifest(WindowsUpdateConstants.ManifestSchema, "stable", _now.ToString("O"),
                revision, floor, new("test-update-key", WindowsUpdateConstants.SupportedAlgorithm), [release]);
            _manifest = JsonSerializer.SerializeToUtf8Bytes(manifest,
                new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower });
            _signature = Convert.ToBase64String(_key.SignData(_manifest, HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence));
        }

        public void Dispose()
        {
            Http.Dispose();
            _key.Dispose();
            if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        }

        private sealed class Handler(Fixture fixture) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                if (fixture.Offline) throw new HttpRequestException("Update origin is offline.");
                var path = request.RequestUri!.AbsolutePath;
                HttpContent content;
                if (path.EndsWith("/update.json", StringComparison.Ordinal))
                {
                    if (fixture.BeforeManifest is { } before) await before(token);
                    content = fixture.StalledBody == "manifest" ? new StreamContent(fixture.Body!) : new ByteArrayContent(fixture._manifest);
                }
                else if (path.EndsWith("/update.json.sig", StringComparison.Ordinal))
                {
                    content = fixture.StalledBody == "signature" ? new StreamContent(fixture.Body!) :
                        new StringContent(fixture.BadSignature ? Convert.ToBase64String(new byte[64]) : fixture._signature);
                }
                else
                {
                    fixture.ArtifactRequests.Add(path);
                    content = Path.GetFileName(path) == fixture.StalledBody
                        ? new StreamContent(fixture.Body!) : new ByteArrayContent(fixture._artifacts[path]);
                    if (fixture.CorruptDependency && path.EndsWith("/Microsoft.VCLibs.x64.14.00.Desktop.appx", StringComparison.Ordinal))
                    {
                        content = new ByteArrayContent(new byte[fixture._artifacts[path].Length]);
                    }
                }
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
            }
        }
    }

    private sealed class StalledStream : Stream
    {
        public TaskCompletionSource Entered { get; } = Signal();
        public bool Cancelled { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            Entered.TrySetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { Cancelled = true; throw; }
            return 0;
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

using Vex.Windows.Client.Updates;
using Vex.Windows.Core.Updates;

namespace Vex.Windows.App.Services;

public sealed partial class NativeUpdateService
{
    private readonly WindowsUpdateCoordinator? _coordinator;
    private readonly string _downloadsFallbackUrl;
    private readonly string _stagingRoot;
    private readonly Action<WindowsUpdateRollbackState> _saveRollbackState;
    private readonly Action<WindowsStagedProvisioningBundle> _launchBootstrap;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private bool _rollbackPersistenceFailed;

    internal NativeUpdateService(WindowsUpdateCoordinator coordinator,
        NativeUpdateSnapshot initialSnapshot, string stagingRoot,
        Action<WindowsUpdateRollbackState> saveRollbackState,
        Action<WindowsStagedProvisioningBundle> launchBootstrap,
        WindowsUpdateRollbackState? rollbackState = null)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentNullException.ThrowIfNull(initialSnapshot);
        ArgumentException.ThrowIfNullOrWhiteSpace(stagingRoot);
        ArgumentNullException.ThrowIfNull(saveRollbackState);
        ArgumentNullException.ThrowIfNull(launchBootstrap);
        _coordinator = coordinator;
        CurrentSnapshot = initialSnapshot.WithRollbackState(rollbackState);
        _stagingRoot = stagingRoot;
        _downloadsFallbackUrl = "https://vexguard.app/downloads";
        _saveRollbackState = saveRollbackState;
        _launchBootstrap = launchBootstrap;
    }

    public NativeUpdateSnapshot CurrentSnapshot { get; private set; }
    public event EventHandler? Changed;
    public string DownloadsFallbackUrl => _downloadsFallbackUrl;

    public async Task<NativeUpdateSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        if (_coordinator is null) return CurrentSnapshot;
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await RefreshCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _operationGate.Release(); }
    }

    private async Task<NativeUpdateSnapshot> RefreshCoreAsync(CancellationToken cancellationToken)
    {
        NativeUpdateSnapshot? verifiedSnapshot = null;
        try
        {
            var assessment = await _coordinator!.CheckForUpdateAsync(cancellationToken).ConfigureAwait(false);
            var assessed = assessment.UpdateAvailable
                ? NativeUpdateSnapshot.Available(assessment.CurrentVersion, assessment.Release!,
                    assessment.CurrentChannel, assessment.CurrentArchitecture, assessment.Release!.Required)
                : NativeUpdateSnapshot.NoUpdate(assessment.CurrentVersion, assessment.CurrentChannel,
                    assessment.CurrentArchitecture, assessment.Reason);
            verifiedSnapshot = NativeUpdateSnapshot.PreserveRequiredUntilSatisfied(CurrentSnapshot,
                assessed.WithRollbackState(assessment.RollbackState));
            cancellationToken.ThrowIfCancellationRequested();
            _rollbackPersistenceFailed = true;
            _saveRollbackState(assessment.RollbackState);
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
        return CurrentSnapshot;
    }

    public async Task<NativeUpdateSnapshot> PrepareAndLaunchAsync(CancellationToken cancellationToken)
    {
        if (_coordinator is null) return CurrentSnapshot;
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var snapshot = CurrentSnapshot;
        try
        {
            // A queued launch must use the newest verified release and rollback
            // persistence result, never a snapshot captured before this gate.
            if (!snapshot.UpdateAvailable || snapshot.Release is null || _rollbackPersistenceFailed)
            {
                snapshot = await RefreshCoreAsync(cancellationToken).ConfigureAwait(false);
                if (!snapshot.UpdateAvailable || snapshot.Release is null || _rollbackPersistenceFailed) return snapshot;
            }
            var staged = await _coordinator.DownloadAndStageProvisioningAsync(
                snapshot.Release!, _stagingRoot, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            _launchBootstrap(staged);
            SetSnapshot(NativeUpdateSnapshot.InstallerLaunched(snapshot, staged.PackagePath));
        }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
            NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            SetSnapshot(NativeUpdateSnapshot.ErrorFrom(snapshot, error.Message));
        }
        finally { _operationGate.Release(); }
        return CurrentSnapshot;
    }

    private void SetSnapshot(NativeUpdateSnapshot snapshot)
    {
        CurrentSnapshot = snapshot;
        Changed?.Invoke(this, EventArgs.Empty);
    }
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
    public string? RequiredVersionFloor { get; init; }
    public string? RequiredTargetVersion { get; init; }

    internal NativeUpdateSnapshot WithRollbackState(WindowsUpdateRollbackState? state) => state is null
        ? this
        : (this with { RequiredVersionFloor = state.RequiredVersionFloor,
            RequiredTargetVersion = state.RequiredTargetVersion })
            .WithMinimumRequiredVersion(MaximumVersion(state.RequiredVersionFloor, state.RequiredTargetVersion));

    private NativeUpdateSnapshot WithMinimumRequiredVersion(string? minimum)
    {
        if (minimum is null) return this;
        var version = WindowsUpdateManifestVerifier.ParseVersion(minimum, "required_version");
        if (WindowsUpdateManifestVerifier.ParseVersion(CurrentVersion, "current_version") >= version) return this;
        var release = Release is not null &&
            WindowsUpdateManifestVerifier.ParseVersion(Release.Version, "release.version") >= version ? Release : null;
        return this with
        {
            UpdateAvailable = true,
            Required = true,
            Release = release,
            State = release is null ? "required_update_pending" : State,
            Message = release is null ? "Для подключения требуется обновление VEX. Проверьте обновления при доступной сети." : Message,
        };
    }

    private static string? MaximumVersion(params string?[] versions)
    {
        string? maximum = null;
        foreach (var value in versions)
            if (value is not null && (maximum is null ||
                WindowsUpdateManifestVerifier.ParseVersion(value, "required_version") >
                    WindowsUpdateManifestVerifier.ParseVersion(maximum, "required_version"))) maximum = value;
        return maximum;
    }

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

    public static NativeUpdateSnapshot InstallerLaunched(NativeUpdateSnapshot previous,
        string stagedPackagePath) => previous with
        {
            State = "installer_launched",
            Message = "Пакет обновления проверен и открыт в системном установщике.",
            StagedPackagePath = stagedPackagePath,
        };

    public static NativeUpdateSnapshot InstallerLaunched(string currentVersion, string channel,
        string architecture, string availableVersion, string stagedPackagePath) =>
        InstallerLaunched(Available(currentVersion, new WindowsUpdateRelease(
            availableVersion, architecture, "msix", stagedPackagePath, string.Empty, string.Empty,
            string.Empty, null, null, null, null, false, null), channel, architecture, false), stagedPackagePath);

    internal static NativeUpdateSnapshot PreserveRequiredUntilSatisfied(
        NativeUpdateSnapshot previous, NativeUpdateSnapshot verified)
    {
        if (!previous.UpdateAvailable || !previous.Required) return verified;
        var target = MaximumVersion(previous.RequiredTargetVersion, verified.RequiredTargetVersion,
            previous.Release is { Required: true } ? previous.Release.Version : null);
        var floor = verified.RequiredVersionFloor ?? previous.RequiredVersionFloor;
        var requiredVersion = MaximumVersion(floor, target);
        if (requiredVersion is null ||
            WindowsUpdateManifestVerifier.ParseVersion(verified.CurrentVersion, "current_version") >=
                WindowsUpdateManifestVerifier.ParseVersion(requiredVersion, "required_version")) return verified;
        var snapshot = verified.UpdateAvailable && verified.Release is not null &&
            WindowsUpdateManifestVerifier.ParseVersion(verified.Release.Version, "release.version") >=
                WindowsUpdateManifestVerifier.ParseVersion(requiredVersion, "required_version")
            ? verified
            : previous with { State = "available", CurrentVersion = verified.CurrentVersion, StagedPackagePath = null };
        return (snapshot with { Required = true, RequiredVersionFloor = floor, RequiredTargetVersion = target })
            .WithMinimumRequiredVersion(requiredVersion);
    }

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
            previous.Required;
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
                message) with { RequiredVersionFloor = previous.RequiredVersionFloor, RequiredTargetVersion = previous.RequiredTargetVersion };
    }
}

using Vex.Windows.Core.Vpn;

internal static class VpnRuntimeLifetimeTests
{
    public static readonly (string Name, Action Run)[] All =
    [
        ("Unconfirmed vendor stop retains protection and authorization", StopFailurePreservesState),
        ("Cancelled cleanup never restores the network before a confirmed stop", StopCancellationPreservesState),
        ("Cancellation after vendor stop retains recovery journal and lease", CancellationAfterStopPreservesJournal),
        ("Partial network restoration retains authorization for retry", RestorationFailureRetainsLease),
        ("Unverified cleanup cannot release authorization", UnverifiedCleanupRetainsLease),
        ("Confirmed cleanup stops before restoration and lease release", ConfirmedCleanupOrder),
        ("Disconnect intent survives restart with an otherwise valid lease", DisconnectSurvivesRestart),
        ("A newer disconnect prevents a pending connect from committing", DisconnectSupersedesConnect),
        ("Storage failure still invalidates a pending connect", StorageFailureSupersedesConnect),
        ("Shutdown drains queued recovery and refuses new callbacks", ShutdownDrainsRecovery),
        ("Shutdown drain honors its deadline without permitting recovery", ShutdownDrainIsBounded),
        ("Host shutdown budget covers pipe drain, quiescence and cleanup", ShutdownBudget),
    ];

    private static void StopFailurePreservesState()
    {
        var state = new CleanupState { StopFailure = new VpnTunnelException("tunnel_stop_failed") };
        Reject<VpnTunnelException>(() => state.CleanupAsync(CancellationToken.None));
        Require(state.TunnelRunning && state.FirewallProtected && state.JournalPresent && state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop"]));
    }

    private static void StopCancellationPreservesState()
    {
        var state = new CleanupState { StopFailure = new OperationCanceledException() };
        Reject<OperationCanceledException>(() => state.CleanupAsync(CancellationToken.None));
        Require(state.TunnelRunning && state.FirewallProtected && state.JournalPresent && state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop"]));
    }

    private static void CancellationAfterStopPreservesJournal()
    {
        using var cancellation = new CancellationTokenSource();
        var state = new CleanupState { AfterStop = cancellation.Cancel };
        Reject<OperationCanceledException>(() => state.CleanupAsync(cancellation.Token));
        Require(!state.TunnelRunning && state.FirewallProtected && state.JournalPresent && state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop"]));
    }

    private static void RestorationFailureRetainsLease()
    {
        var state = new CleanupState { RestoreFailure = new IOException("fixture restoration failed") };
        Reject<IOException>(() => state.CleanupAsync(CancellationToken.None));
        Require(!state.TunnelRunning && state.JournalPresent && state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop", "restore"]));
    }

    private static void UnverifiedCleanupRetainsLease()
    {
        var state = new CleanupState { VerificationSucceeds = false };
        Reject<VpnTunnelException>(() => state.CleanupAsync(CancellationToken.None));
        Require(!state.TunnelRunning && state.JournalPresent && state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop", "restore", "verify"]));
    }

    private static void ConfirmedCleanupOrder()
    {
        var state = new CleanupState();
        state.CleanupAsync(CancellationToken.None).GetAwaiter().GetResult();
        Require(!state.TunnelRunning && !state.FirewallProtected && !state.JournalPresent && !state.LeasePresent);
        Require(state.Events.SequenceEqual(["stop", "restore", "verify", "release"]));
    }

    private static void DisconnectSurvivesRestart() => WithIntent(path =>
    {
        var firstProcess = new VpnDisconnectIntent(path);
        firstProcess.Record();
        // An unexpired lease alone must not be interpreted as connection desire.
        var validLease = DateTimeOffset.UtcNow.AddHours(1);
        var restartedProcess = new VpnDisconnectIntent(path);
        Require(validLease > DateTimeOffset.UtcNow && restartedProcess.IsRecorded);
        var newConnection = restartedProcess.Record();
        restartedProcess.ClearForVerifiedConnection(newConnection);
        Require(!new VpnDisconnectIntent(path).IsRecorded);
    });

    private static void DisconnectSupersedesConnect() => WithIntent(path =>
    {
        var intent = new VpnDisconnectIntent(path);
        var connecting = intent.Record();
        intent.Record();
        Reject<VpnTunnelException>(() =>
        {
            intent.ClearForVerifiedConnection(connecting);
            return Task.CompletedTask;
        });
        Require(intent.IsRecorded);
    });

    private static void StorageFailureSupersedesConnect() => WithIntent(path =>
    {
        var intent = new VpnDisconnectIntent(path);
        var connecting = intent.Record();
        Reject<IOException>(() =>
        {
            intent.Record(() => throw new IOException("fixture disk failure"));
            return Task.CompletedTask;
        });
        Reject<VpnTunnelException>(() =>
        {
            intent.ClearForVerifiedConnection(connecting);
            return Task.CompletedTask;
        });
        Require(intent.IsRecorded);
    });

    private static void ShutdownDrainsRecovery() => ShutdownDrainsRecoveryAsync().GetAwaiter().GetResult();

    private static async Task ShutdownDrainsRecoveryAsync()
    {
        var work = new VpnRuntimeBackgroundWork();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var restarts = 0;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        Require(work.Run(async token =>
        {
            started.SetResult();
            await released.Task.ConfigureAwait(false);
            if (!token.IsCancellationRequested) { Interlocked.Increment(ref restarts); }
        }));
        try
        {
            await started.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            work.Stop();
            Require(!work.Run(_ => { Interlocked.Increment(ref restarts); return Task.CompletedTask; }));
            var drained = work.DrainAsync(deadline.Token);
            Require(!drained.IsCompleted);
            released.SetResult();
            await drained.ConfigureAwait(false);
            Require(restarts == 0);
        }
        finally { work.Stop(); released.TrySetResult(); }
    }

    private static void ShutdownDrainIsBounded() => ShutdownDrainIsBoundedAsync().GetAwaiter().GetResult();

    private static async Task ShutdownDrainIsBoundedAsync()
    {
        var work = new VpnRuntimeBackgroundWork();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        Require(work.Run(async _ =>
        {
            started.SetResult();
            await released.Task.ConfigureAwait(false);
        }));
        try
        {
            await started.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            work.Stop();
            using var elapsed = new CancellationTokenSource();
            elapsed.Cancel();
            Reject<OperationCanceledException>(() => work.DrainAsync(elapsed.Token));
            Require(!work.Run(_ => Task.CompletedTask));
            released.SetResult();
            await work.DrainAsync(deadline.Token).ConfigureAwait(false);
        }
        finally { work.Stop(); released.TrySetResult(); }
    }

    private static void ShutdownBudget() => Require(
        VpnRuntimeLifetimePolicy.HostShutdownTimeout >
        VpnRuntimeLifetimePolicy.PipeShutdownTimeout +
        VpnRuntimeLifetimePolicy.QuiesceTimeout +
        VpnRuntimeLifetimePolicy.CleanupTimeout);

    private static void WithIntent(Action<string> test)
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-lifetime-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try { test(Path.Combine(directory, "disconnect-intent")); }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static void Reject<T>(Func<Task> operation) where T : Exception
    {
        try { operation().GetAwaiter().GetResult(); }
        catch (T) { return; }
        throw new Exception("Expected runtime lifetime failure was not reported.");
    }

    private static void Require(bool condition)
    {
        if (!condition) { throw new Exception("VPN runtime lifetime assertion failed."); }
    }

    private sealed class CleanupState
    {
        public readonly List<string> Events = [];
        public bool TunnelRunning = true;
        public bool FirewallProtected = true;
        public bool JournalPresent = true;
        public bool LeasePresent = true;
        public bool VerificationSucceeds = true;
        public Exception? StopFailure;
        public Exception? RestoreFailure;
        public Action? AfterStop;

        public Task CleanupAsync(CancellationToken cancellationToken) =>
            VpnRuntimeLifetimePolicy.StopAndRestoreAsync(
                _ =>
                {
                    Events.Add("stop");
                    if (StopFailure is not null) { throw StopFailure; }
                    TunnelRunning = false;
                    AfterStop?.Invoke();
                    return Task.CompletedTask;
                },
                _ =>
                {
                    Require(!TunnelRunning);
                    Events.Add("restore");
                    if (RestoreFailure is not null) { throw RestoreFailure; }
                    FirewallProtected = false;
                    return Task.CompletedTask;
                },
                () =>
                {
                    Events.Add("verify");
                    if (VerificationSucceeds) { JournalPresent = false; }
                    return VerificationSucceeds;
                },
                () => { Events.Add("release"); LeasePresent = false; },
                cancellationToken);
    }
}

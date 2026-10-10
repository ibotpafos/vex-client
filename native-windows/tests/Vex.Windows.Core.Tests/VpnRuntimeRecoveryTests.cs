using Vex.Windows.Core.Vpn;

internal static class VpnRuntimeRecoveryTests
{
    public static readonly (string Name, Action Run)[] All =
    [
        ("Disconnect fences a handover restart after the old vendor stops", DisconnectFencesPendingRestart),
        ("Disconnect interrupts handover route and handshake waits", DisconnectCancelsRepairWaits),
        ("A repair already starting orders disconnect before every later restart", DisconnectOrdersScmStart),
        ("A canceled repair does not cancel the lifetime watchdog or a later connect", LaterRepairHasIndependentIntent),
        ("Service shutdown cancels an in-flight repair and prevents its start", ShutdownCancelsRepair),
        ("A running vendor without its adapter exposes bounded automatic recovery", MissingAdapterIsRecoverableError),
        ("Pending SCM start remains a real transition and healthy runtime stays connected", StatusTransitionsRemainAccurate),
    ];

    private static void DisconnectFencesPendingRestart() => DisconnectFencesPendingRestartAsync().GetAwaiter().GetResult();

    private static async Task DisconnectFencesPendingRestartAsync()
    {
        using var lifetime = new CancellationTokenSource();
        using var attempt = new VpnRuntimeRepairAttempt(lifetime.Token);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var stopped = Completion();
        var releaseStop = Completion();
        var starts = 0;
        var repair = Task.Run(async () =>
        {
            stopped.SetResult();
            await releaseStop.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            attempt.StartIfCurrent(() => Interlocked.Increment(ref starts));
        });
        try
        {
            await stopped.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            // Disconnect can record its intent while repair holds the runtime
            // operation gate. Even a completed stop must not permit its start.
            attempt.Supersede();
            releaseStop.SetResult();
            await CanceledAsync(repair.WaitAsync(deadline.Token)).ConfigureAwait(false);
            Require(starts == 0 && !lifetime.IsCancellationRequested,
                "A superseded repair restarted the vendor or stopped the lifetime watchdog.");
        }
        finally
        {
            releaseStop.TrySetResult();
            await ObserveAsync(repair).ConfigureAwait(false);
        }
    }

    private static void DisconnectCancelsRepairWaits() => DisconnectCancelsRepairWaitsAsync().GetAwaiter().GetResult();

    private static async Task DisconnectCancelsRepairWaitsAsync()
    {
        foreach (var stage in new[] { "route reconciliation", "fresh handshake" })
        {
            using var attempt = new VpnRuntimeRepairAttempt(CancellationToken.None);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var waiting = Completion();
            var wait = Task.Run(async () =>
            {
                waiting.SetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, attempt.Token).ConfigureAwait(false);
            });
            await waiting.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            attempt.Supersede();
            await CanceledAsync(wait.WaitAsync(deadline.Token)).ConfigureAwait(false);
            Require(attempt.Token.IsCancellationRequested, "Disconnect did not interrupt " + stage + ".");
        }
    }

    private static void DisconnectOrdersScmStart() => DisconnectOrdersScmStartAsync().GetAwaiter().GetResult();

    private static async Task DisconnectOrdersScmStartAsync()
    {
        using var attempt = new VpnRuntimeRepairAttempt(CancellationToken.None);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var releaseStart = new ManualResetEventSlim();
        var enteringStart = Completion();
        var disconnectRequested = Completion();
        var starts = 0;
        var start = Task.Run(() => attempt.StartIfCurrent(() =>
        {
            enteringStart.SetResult();
            Require(releaseStart.Wait(TimeSpan.FromSeconds(5)), "The bounded SCM start barrier timed out.");
            Interlocked.Increment(ref starts);
        }));
        Task? disconnect = null;
        try
        {
            await enteringStart.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            disconnect = Task.Run(() =>
            {
                disconnectRequested.SetResult();
                attempt.Supersede();
            });
            await disconnectRequested.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
            Require(!disconnect.IsCompleted, "Disconnect crossed an in-progress synchronous SCM start.");
            releaseStart.Set();
            await Task.WhenAll(start, disconnect).WaitAsync(deadline.Token).ConfigureAwait(false);
            await CanceledAsync(Task.Run(() => attempt.StartIfCurrent(() => Interlocked.Increment(ref starts))))
                .ConfigureAwait(false);
            Require(starts == 1, "A start ran after disconnect completed its supersession.");
        }
        finally
        {
            releaseStart.Set();
            await ObserveAsync(start).ConfigureAwait(false);
            if (disconnect is not null) { await ObserveAsync(disconnect).ConfigureAwait(false); }
        }
    }

    private static void LaterRepairHasIndependentIntent()
    {
        using var lifetime = new CancellationTokenSource();
        using var previous = new VpnRuntimeRepairAttempt(lifetime.Token);
        previous.Supersede();
        using var next = new VpnRuntimeRepairAttempt(lifetime.Token);
        var starts = 0;
        next.StartIfCurrent(() => starts++);
        Require(starts == 1 && !next.Token.IsCancellationRequested && !lifetime.IsCancellationRequested,
            "Canceling old recovery poisoned a later explicit connection.");
    }

    private static void ShutdownCancelsRepair()
    {
        using var lifetime = new CancellationTokenSource();
        using var attempt = new VpnRuntimeRepairAttempt(lifetime.Token);
        lifetime.Cancel();
        var started = false;
        CanceledAsync(Task.Run(() => attempt.StartIfCurrent(() => started = true))).GetAwaiter().GetResult();
        Require(!started && attempt.Token.IsCancellationRequested,
            "A repair restarted the vendor after host shutdown.");
    }

    private static void MissingAdapterIsRecoverableError()
    {
        var status = VpnRuntimeStatusPolicy.FromServiceObservation(true, false, "fi-1",
            VpnTunnelDiagnostics.Empty with { Findings = ["tunnel_adapter_missing"] });
        Require(status.Phase == VpnConnectionPhase.Error && status.LocationId == "fi-1" &&
            status.ErrorCode == "tunnel_network_degraded", "Adapter loss remained indefinitely Connecting.");
        var snapshot = new VpnConnectionSnapshot(status.Phase, status.LocationId, 1, status.ErrorCode)
        {
            Diagnostics = status.Diagnostics,
        };
        var now = DateTimeOffset.UtcNow;
        Require(VpnRecoveryPolicy.ShouldRecover(snapshot, true, true, true, now, null, null),
            "Adapter loss could not reach admitted profile/failover recovery.");
        Require(!VpnRecoveryPolicy.ShouldRecover(snapshot, true, false, true, now, null, null) &&
            !VpnRecoveryPolicy.ShouldRecover(snapshot, false, true, true, now, null, null),
            "Adapter recovery ignored the recovery preference or explicit disconnect.");
    }

    private static void StatusTransitionsRemainAccurate()
    {
        var starting = VpnRuntimeStatusPolicy.FromServiceObservation(false, true, "fi-1", VpnTunnelDiagnostics.Empty);
        Require(starting.Phase == VpnConnectionPhase.Connecting && starting.ErrorCode is null,
            "An actual SCM start was labeled a failed established connection.");
        var diagnostics = VpnTunnelDiagnostics.Empty with
        {
            AdapterName = "vex", AdapterIndex = 7, LatestHandshakeAt = DateTimeOffset.UtcNow,
            Ipv4RouteOk = true, Ipv6RouteOk = true, DnsConfigured = true, EndpointBypassOk = true,
        };
        var connected = VpnRuntimeStatusPolicy.FromServiceObservation(true, false, "fi-1", diagnostics);
        Require(connected.Phase == VpnConnectionPhase.Connected && connected.Diagnostics == diagnostics,
            "Validated running service stopped reporting its connection.");
        Require(VpnRuntimeStatusPolicy.FromServiceObservation(false, false, "fi-1", diagnostics).LocationId is null,
            "A disconnected vendor retained an active location.");
    }

    private static TaskCompletionSource Completion() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static async Task CanceledAsync(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        throw new InvalidOperationException("The superseded repair was not canceled.");
    }

    private static async Task ObserveAsync(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}

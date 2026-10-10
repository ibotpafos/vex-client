using Vex.Windows.App.Services;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class VpnUiStateServiceTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await FailuresAreRecordedBeforeTheNextOperationAsync();
        await CanceledQueuedOperationsNeverRunAsync();
        await ExplicitDisconnectCancelsRecoveryAndReleasesTheGateAsync();
        await TerminalFailuresClearConnectionIntentAsync();
        await RefreshUsesInjectedDiagnosticsAsync();
        await ConfirmedShutdownRejectsQueuedConnectionsAsync();
        await FailedLogoutCleanupRemainsRetryableAsync();
        await QueuedCleanupHonorsNewConnectionIntentAsync();
        ExplicitDisconnectCannotBeRestored();
    }

    private static async Task FailuresAreRecordedBeforeTheNextOperationAsync()
    {
        var service = Create();
        var diagnostics = VpnTunnelDiagnostics.Empty with
        {
            AdapterName = "VEX",
            AdapterIndex = 7,
            RxBytes = 4096,
            TxBytes = -1,
            LeakProtection = VpnLeakProtectionState.Degraded,
        };
        service.Apply(Response(new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 10, null)
        {
            Diagnostics = diagnostics,
        }));
        var entered = Signal();
        var fail = Signal();
        var first = service.RunAsync(async _ =>
        {
            entered.SetResult();
            await fail.Task;
            throw new IOException("service restarted");
        }, CancellationToken.None);
        await entered.Task;
        var nextRan = false;
        var next = service.RunAsync(_ =>
        {
            nextRan = true;
            Assert(service.Snapshot.ErrorCode == "vpn_service_unavailable",
                "A failed operation must record its status before the next operation starts.");
            Assert(service.Snapshot.Diagnostics == diagnostics,
                "A client failure must preserve adapter and firewall cleanup evidence.");
            Assert(VpnConnectionActionPolicy.ShouldDisconnect(service.Snapshot),
                "A failure with a remaining adapter must offer disconnect.");
            Assert(service.ReceivedBytes == 4096 && service.SentBytes == 0,
                "Traffic must remain available and negative diagnostic counters must be clamped.");
            return Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(11)));
        }, CancellationToken.None);
        Assert(!nextRan, "A second operation must wait for the active operation.");
        fail.SetResult();
        await ExpectAsync<IOException>(first);
        await next;
        Assert(service.Snapshot.Phase == VpnConnectionPhase.Disconnected && service.Snapshot.Sequence == 11,
            "An old poll failure must not replace a newer confirmed disconnect.");
        Assert(service.ReceivedBytes == 0 && service.SentBytes == 0,
            "A confirmed disconnect must remove stale traffic counters.");
    }

    private static async Task CanceledQueuedOperationsNeverRunAsync()
    {
        var service = Create();
        var entered = Signal();
        var release = Signal();
        var first = service.RunAsync(async _ =>
        {
            entered.SetResult();
            await release.Task;
            return Response(VpnConnectionSnapshot.Disconnected(2));
        }, CancellationToken.None);
        await entered.Task;
        using var cancellation = new CancellationTokenSource();
        var ran = false;
        var queued = service.RunAsync(_ =>
        {
            ran = true;
            return Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(3)));
        }, cancellation.Token);
        cancellation.Cancel();
        await ExpectAsync<OperationCanceledException>(queued);
        Assert(!ran && service.Snapshot.Phase == VpnConnectionPhase.Disconnected && service.Snapshot.Sequence == 0,
            "Canceled queued work must neither send an IPC request nor publish an error.");
        release.SetResult();
        await first;
        await service.RefreshAsync(CancellationToken.None);
    }

    private static async Task ExplicitDisconnectCancelsRecoveryAndReleasesTheGateAsync()
    {
        var service = Create();
        service.Apply(Response(new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 5, null)));
        service.MarkConnectionDesired(true);
        using var recoveryCancellation = new CancellationTokenSource();
        service.DesiredChanged += (_, _) =>
        {
            if (!service.ConnectionDesired) recoveryCancellation.Cancel();
        };
        var entered = Signal();
        var recovery = service.RunAsync(async token =>
        {
            entered.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException("Canceled recovery cannot complete.");
        }, recoveryCancellation.Token, recordCancellationFailure: false);
        await entered.Task;
        service.MarkConnectionDesired(false);
        await ExpectAsync<OperationCanceledException>(recovery);
        Assert(service.Snapshot.Phase == VpnConnectionPhase.Connected && service.Snapshot.ErrorCode is null,
            "Intentional recovery cancellation must preserve the last confirmed service state.");
        await service.RunAsync(_ => Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(6))), CancellationToken.None);
        service.RestoreConnectionDesired();
        Assert(!service.ConnectionDesired && service.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "Explicit disconnect must persist after canceled recovery and a subsequent status refresh.");
    }

    private static async Task TerminalFailuresClearConnectionIntentAsync()
    {
        var service = Create();
        service.MarkConnectionDesired(true);
        await ExpectAsync<NativeClientFlowException>(service.RunAsync(
            _ => Task.FromException<VpnServiceResponse>(new NativeClientFlowException("vpn_entitlement_required")),
            CancellationToken.None));
        Assert(!service.ConnectionDesired && service.Snapshot.ErrorCode == "vpn_entitlement_required",
            "A terminal entitlement exception must stop automatic recovery.");
        service.MarkConnectionDesired(true);
        await service.RunAsync(_ => Task.FromResult(new VpnServiceResponse("terminal", false,
            new VpnConnectionSnapshot(VpnConnectionPhase.Error, null, 1, "sign_in_required"), "sign_in_required")),
            CancellationToken.None);
        Assert(!service.ConnectionDesired, "A terminal service response must also stop automatic recovery.");
    }

    private static async Task RefreshUsesInjectedDiagnosticsAsync()
    {
        var calls = 0;
        using var cancellation = new CancellationTokenSource();
        var service = new VpnUiStateService(token =>
        {
            Assert(token == cancellation.Token, "Diagnostic polling must pass caller cancellation to IPC.");
            calls++;
            return Task.FromResult(Response(new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "fi-1", 7, null)
            {
                Diagnostics = VpnTunnelDiagnostics.Empty with { RxBytes = 1024, TxBytes = 2048 },
            }));
        });
        await service.RefreshAsync(cancellation.Token);
        Assert(calls == 1 && service.Snapshot.LocationId == "fi-1" && service.ReceivedBytes == 1024 && service.SentBytes == 2048,
            "The injected production diagnostic path must publish status and traffic together.");
    }

    private static void ExplicitDisconnectCannotBeRestored()
    {
        var service = Create();
        service.RestoreConnectionDesired();
        Assert(service.ConnectionDesired && !service.HasExplicitConnectionIntent,
            "A running tunnel may restore intent on application startup.");
        service.MarkConnectionDesired(false);
        Parallel.For(0, 100, _ => service.RestoreConnectionDesired());
        Assert(!service.ConnectionDesired && service.HasExplicitConnectionIntent,
            "A startup poll must never undo explicit disconnect intent.");
    }

    private static async Task ConfirmedShutdownRejectsQueuedConnectionsAsync()
    {
        var service = Create();
        service.MarkConnectionDesired(false);
        var entered = Signal();
        var cleanupConfirmed = Signal();
        var exit = service.RunAsync(async _ =>
        {
            entered.SetResult();
            await cleanupConfirmed.Task;
            service.CompleteShutdown();
            return Response(VpnConnectionSnapshot.Disconnected(20));
        }, CancellationToken.None);
        await entered.Task;
        var connected = false;
        var queuedConnect = service.RunAsync(_ =>
        {
            connected = true;
            return Task.FromResult(Response(new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 21, null)));
        }, CancellationToken.None);
        var cleanupRan = false;
        var queuedCleanup = service.DisconnectIfUnwantedAsync(_ =>
        {
            cleanupRan = true;
            return Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(21)));
        }, CancellationToken.None);
        cleanupConfirmed.SetResult();
        await exit;
        await ExpectAsync<OperationCanceledException>(queuedConnect);
        await ExpectAsync<OperationCanceledException>(queuedCleanup);
        service.MarkConnectionDesired(true);
        Assert(!connected && !cleanupRan && !service.ConnectionDesired && service.Snapshot.Phase == VpnConnectionPhase.Disconnected &&
            service.Snapshot.Sequence == 20 && service.Snapshot.ErrorCode is null,
            "A queued connect must not restart the service tunnel after confirmed app shutdown.");
    }

    private static async Task FailedLogoutCleanupRemainsRetryableAsync()
    {
        var service = Create();
        var active = new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 10, null)
        {
            Diagnostics = VpnTunnelDiagnostics.Empty with { AdapterName = "VEX", AdapterIndex = 7 },
        };
        service.Apply(Response(active));
        // Missing persisted state after a failed logout establishes unwanted
        // intent on startup before adoption of the still-running tunnel.
        service.MarkConnectionDesired(false);
        service.RestoreConnectionDesired();
        var attempts = 0;
        await ExpectAsync<OperationCanceledException>(service.DisconnectIfUnwantedAsync(_ =>
        {
            attempts++;
            return Task.FromException<VpnServiceResponse>(new OperationCanceledException("IPC timeout"));
        }, CancellationToken.None));
        Assert(!service.ConnectionDesired && VpnRecoveryPolicy.RequiresDisconnect(service.Snapshot),
            "An IPC timeout after logout must preserve unwanted intent and active cleanup evidence.");
        service.Apply(Response(active with { Sequence = 11 }));
        await service.DisconnectIfUnwantedAsync(_ =>
        {
            attempts++;
            return Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(12)));
        }, CancellationToken.None);
        await service.DisconnectIfUnwantedAsync(_ =>
        {
            attempts++;
            throw new InvalidOperationException("A confirmed disconnect must not send more cleanup IPC.");
        }, CancellationToken.None);
        Assert(attempts == 2 && !service.ConnectionDesired && service.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "A service becoming available after logout must allow bounded cleanup without reconnecting.");
    }

    private static async Task QueuedCleanupHonorsNewConnectionIntentAsync()
    {
        var service = Create();
        service.Apply(Response(new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 5, null)));
        service.MarkConnectionDesired(false);
        var entered = Signal();
        var release = Signal();
        var first = service.RunAsync(async _ =>
        {
            entered.SetResult();
            await release.Task;
            return Response(service.Snapshot);
        }, CancellationToken.None);
        await entered.Task;
        var cleanupRan = false;
        var queued = service.DisconnectIfUnwantedAsync(_ =>
        {
            cleanupRan = true;
            return Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(6)));
        }, CancellationToken.None);
        service.MarkConnectionDesired(true);
        release.SetResult();
        await first;
        await queued;
        Assert(!cleanupRan && service.ConnectionDesired && service.Snapshot.Phase == VpnConnectionPhase.Connected,
            "Queued cleanup must recheck the user's newer connect intent after acquiring the shared gate.");
    }

    private static VpnUiStateService Create() => new(_ =>
        Task.FromResult(Response(VpnConnectionSnapshot.Disconnected())));

    private static VpnServiceResponse Response(VpnConnectionSnapshot snapshot) =>
        new(Guid.NewGuid().ToString("N"), true, snapshot, null);

    private static TaskCompletionSource Signal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static async Task ExpectAsync<T>(Task task) where T : Exception
    {
        try { await task.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

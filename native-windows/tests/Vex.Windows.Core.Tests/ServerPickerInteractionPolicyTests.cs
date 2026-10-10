using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Session;

internal static class ServerPickerInteractionPolicyTests
{
    public static void Run()
    {
        string[] refreshedIds = ["fi-1", "de-1", "nl-1"];
        Require(ServerPickerInteractionPolicy.RetainSelection("DE-1", "fi-1", refreshedIds) == "de-1",
            "Refreshing or reordering the catalog must keep the keyboard-highlighted node, rather than apply the current tunnel's node.");
        Require(ServerPickerInteractionPolicy.RetainSelection("de-1", "fi-1", ["fi-1", "nl-1"]) == "fi-1",
            "A filter that removes the highlighted node should fall back to the committed node only when it remains visible.");
        Require(ServerPickerInteractionPolicy.RetainSelection("de-1", "fi-1", ["nl-1"]) is null,
            "A hidden node must never remain selected for keyboard activation.");
        Require(ServerPickerInteractionPolicy.RetainSelection("de-1", "fi-1", []) is null,
            "An empty catalog must clear the keyboard selection.");
        foreach (var phase in Enum.GetValues<VpnConnectionPhase>())
        {
            Require(!ServerPickerInteractionPolicy.CanSelect(phase, connectionInFlight: true, cleanupInFlight: false),
                "A pending connect must block selection even before the service reports Connecting.");
            Require(!ServerPickerInteractionPolicy.CanSelect(phase, connectionInFlight: false, cleanupInFlight: true),
                "Cancellation cleanup must block selection even when its last snapshot is Connected or Disconnected.");
        }
        Require(!ServerPickerInteractionPolicy.CanSelect(VpnConnectionPhase.Connecting, false, false) &&
            !ServerPickerInteractionPolicy.CanSelect(VpnConnectionPhase.Disconnecting, false, false),
            "A service-side transition must block selection even without a local request.");
        Require(ServerPickerInteractionPolicy.CanSelect(VpnConnectionPhase.Connected, false, false) &&
            ServerPickerInteractionPolicy.CanSelect(VpnConnectionPhase.Disconnected, false, false) &&
            ServerPickerInteractionPolicy.CanSelect(VpnConnectionPhase.Error, false, false),
            "Stable states must allow choosing a server or preparing the next connection.");
        BusyAdmissionPreservesTheActiveRequestAsync().GetAwaiter().GetResult();
        AcceptedSwitchRemainsCancelableAsync().GetAwaiter().GetResult();
        CleanupAdmissionPreservesDisconnectedIntentAsync().GetAwaiter().GetResult();
    }

    private static async Task BusyAdmissionPreservesTheActiveRequestAsync()
    {
        var service = Create();
        service.Apply(Response(new(VpnConnectionPhase.Connected, "de-1", 1, null)));
        service.MarkConnectionDesired(true);
        var entered = Signal();
        var release = Signal();
        var activeCanceled = false;
        var active = service.RunConnectionAsync(async token =>
        {
            using var registration = token.Register(() => activeCanceled = true);
            entered.SetResult();
            await release.Task;
            return Response(new(VpnConnectionPhase.Connected, "de-1", 2, null));
        }, CancellationToken.None);
        await entered.Task;
        var preferencesOrIpcTouched = false;
        var rejection = service.RunConnectionAsync(_ =>
        {
            preferencesOrIpcTouched = true;
            return Task.FromResult(Response(new(VpnConnectionPhase.Connected, "fi-1", 3, null)));
        }, CancellationToken.None, onlyWhenIdle: true);
        try { await rejection; throw new InvalidOperationException("A busy picker request was admitted."); }
        catch (NativeClientFlowException error) when (error.Code == "vpn_operation_in_progress") { }
        Require(service.ConnectionDesired && service.IsConnectionInFlight && !activeCanceled &&
            !preferencesOrIpcTouched && service.Snapshot.LocationId == "de-1" && service.Snapshot.ErrorCode is null,
            "Rejecting a picker switch must leave the existing request, intent, preferences and IPC unchanged.");
        release.SetResult();
        await active;
    }

    private static async Task AcceptedSwitchRemainsCancelableAsync()
    {
        var service = Create();
        service.Apply(Response(new(VpnConnectionPhase.Connected, "de-1", 1, null)));
        service.MarkConnectionDesired(true);
        var entered = Signal();
        var canceled = false;
        var selection = service.RunConnectionAsync(async token =>
        {
            entered.SetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            catch (OperationCanceledException) { canceled = true; throw; }
            return Response(new(VpnConnectionPhase.Connected, "fi-1", 2, null));
        }, CancellationToken.None, onlyWhenIdle: true);
        await entered.Task;
        var cleanup = service.CancelConnectionAsync(_ => Task.FromResult(Response(VpnConnectionSnapshot.Disconnected(3))),
            CancellationToken.None);
        try { await selection; throw new InvalidOperationException("A canceled picker switch completed."); }
        catch (OperationCanceledException) { }
        await cleanup;
        Require(canceled && !service.ConnectionDesired && !service.IsConnectionInFlight &&
            service.Snapshot.Phase == VpnConnectionPhase.Disconnected,
            "An admitted picker switch must use shared cancellation and confirm service cleanup.");
    }

    private static async Task CleanupAdmissionPreservesDisconnectedIntentAsync()
    {
        var service = Create();
        service.MarkConnectionDesired(true);
        var entered = Signal();
        var release = Signal();
        var cleanup = service.CancelConnectionAsync(async _ =>
        {
            entered.SetResult();
            await release.Task;
            return Response(VpnConnectionSnapshot.Disconnected(2));
        }, CancellationToken.None);
        await entered.Task;
        var ran = false;
        try
        {
            await service.RunConnectionAsync(_ =>
            {
                ran = true;
                return Task.FromResult(Response(new(VpnConnectionPhase.Connected, "fi-1", 3, null)));
            }, CancellationToken.None, onlyWhenIdle: true);
            throw new InvalidOperationException("A picker switch was admitted during cleanup.");
        }
        catch (NativeClientFlowException error) when (error.Code == "vpn_operation_in_progress") { }
        Require(!ran && !service.ConnectionDesired && service.IsConnectionCleanupInFlight,
            "Rejecting during cancellation cleanup must never recreate connection intent.");
        release.SetResult();
        await cleanup;
    }

    private static VpnUiStateService Create() => new(_ => Task.FromResult(Response(VpnConnectionSnapshot.Disconnected())));
    private static VpnServiceResponse Response(VpnConnectionSnapshot snapshot) => new(Guid.NewGuid().ToString("N"), true, snapshot, null);
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

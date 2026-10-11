using System.Net;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class VpnFailurePresentationTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        foreach (var error in new Exception[]
        {
            new NativeClientFlowException("vpn_entitlement_required"),
            new VexApiException(HttpStatusCode.Forbidden, "vpn_entitlement_required"),
            new NativeClientFlowException("vpn_device_limit_reached"),
            new VexApiException(HttpStatusCode.Conflict, "vpn_device_limit_reached"),
        })
        {
            var service = Create();
            var connected = Connected();
            service.Apply(new VpnServiceResponse("connected", true, connected, null));
            service.MarkConnectionDesired(true);
            await ExpectOriginalFailureAsync(service.RunConnectionAsync(
                _ => Task.FromException<VpnServiceResponse>(error), CancellationToken.None), error);
            var code = VpnFailurePresentation.CodeFromException(error);
            Require(service.Snapshot is { Phase: VpnConnectionPhase.Error } &&
                service.Snapshot.ErrorCode == code && !service.ConnectionDesired &&
                service.Snapshot.Diagnostics == connected.Diagnostics,
                "A typed account-access failure must preserve its code/cleanup evidence and clear automatic connection intent.");
            Require(!VpnRecoveryPolicy.ShouldRecover(service.Snapshot, service.ConnectionDesired, true, true,
                DateTimeOffset.UtcNow, null, null) &&
                VpnRecoveryPolicy.RequiresDisconnect(service.Snapshot),
                "Account-access failures must stop reconnects while retaining cleanup for an existing adapter.");
            var message = VpnFailurePresentation.MessageFor(code);
            Require(VpnFailurePresentation.RequiresAccountAction(code) && message is not null &&
                message.Contains("«Аккаунт»", StringComparison.Ordinal) &&
                (code == "vpn_entitlement_required"
                    ? message.Contains("подписка", StringComparison.Ordinal)
                    : message.Contains("устройств", StringComparison.Ordinal)),
                "Home and tray guidance must lead to subscription or device management, using shared vetted copy.");
        }

        var responseService = Create();
        responseService.MarkConnectionDesired(true);
        await responseService.RunConnectionAsync(_ => Task.FromResult(new VpnServiceResponse("limit", false,
            VpnConnectionSnapshot.ClientFailure(VpnConnectionSnapshot.Disconnected(), "vpn_device_limit_reached"),
            "vpn_device_limit_reached")), CancellationToken.None);
        Require(!responseService.ConnectionDesired && responseService.Snapshot.ErrorCode == "vpn_device_limit_reached",
            "A device-limit response must stop automatic recovery just like the typed exception.");

        var timeout = new TaskCanceledException("untrusted backend text",
            new TimeoutException("private diagnostic detail"), CancellationToken.None);
        var timeoutService = Create();
        timeoutService.MarkConnectionDesired(true);
        await ExpectOriginalFailureAsync(timeoutService.RunConnectionAsync(
            _ => Task.FromException<VpnServiceResponse>(timeout), CancellationToken.None), timeout);
        var timeoutMessage = VpnFailurePresentation.MessageFor(timeoutService.Snapshot.ErrorCode);
        Require(timeoutService.Snapshot.ErrorCode == VpnFailurePresentation.NetworkTimeout &&
            timeoutService.ConnectionDesired && !VpnFailurePresentation.RequiresAccountAction(timeoutService.Snapshot.ErrorCode) &&
            timeoutMessage is not null && timeoutMessage.Contains("интернет", StringComparison.Ordinal) &&
            !timeoutMessage.Contains(timeout.Message, StringComparison.Ordinal) &&
            !timeoutMessage.Contains(timeout.InnerException!.Message, StringComparison.Ordinal),
            "A typed API deadline must be visible as a transient network timeout, without service repair or backend text.");
        Require(VpnRecoveryPolicy.ShouldRecover(timeoutService.Snapshot, timeoutService.ConnectionDesired,
            true, true, DateTimeOffset.UtcNow, null, null),
            "A transient API deadline must remain eligible for bounded automatic recovery.");

        var cancellationService = Create();
        cancellationService.MarkConnectionDesired(true);
        var beforeCancellation = cancellationService.Snapshot;
        using var cancellation = new CancellationTokenSource();
        try
        {
            await cancellationService.RunConnectionAsync(token =>
            {
                cancellation.Cancel();
                token.ThrowIfCancellationRequested();
                throw new InvalidOperationException("Canceled connection unexpectedly ran.");
            }, cancellation.Token);
            throw new InvalidOperationException("Caller cancellation was swallowed.");
        }
        catch (OperationCanceledException error) when (cancellation.IsCancellationRequested)
        {
            Require(!VpnFailurePresentation.IsNetworkTimeout(error) &&
                cancellationService.Snapshot == beforeCancellation,
                "An explicit caller cancellation must remain silent and must not manufacture a network timeout.");
        }

        var unknown = new VexApiException(HttpStatusCode.Forbidden, "untrusted backend text <private>");
        var unknownService = Create();
        await ExpectOriginalFailureAsync(unknownService.RunAsync(
            _ => Task.FromException<VpnServiceResponse>(unknown), CancellationToken.None), unknown);
        Require(unknownService.Snapshot.ErrorCode == "vpn_service_unavailable" &&
            VpnFailurePresentation.MessageFor(unknown.Code) is null &&
            !VpnFailurePresentation.RequiresAccountAction(unknown.Code),
            "An unknown API code must not be reflected into the snapshot or product guidance.");
    }

    private static VpnUiStateService Create() => new(_ => Task.FromResult(new VpnServiceResponse(
        "status", true, VpnConnectionSnapshot.Disconnected(), null)));

    private static VpnConnectionSnapshot Connected() => new(VpnConnectionPhase.Connected, "de-1", 5, null)
    {
        Diagnostics = VpnTunnelDiagnostics.Empty with
        {
            AdapterName = "VEX", AdapterIndex = 7, LeakProtection = VpnLeakProtectionState.Armed,
        },
    };

    private static async Task ExpectOriginalFailureAsync(Task<VpnServiceResponse> operation, Exception expected)
    {
        try { await operation; }
        catch (Exception actual) when (ReferenceEquals(actual, expected)) { return; }
        throw new InvalidOperationException("The real state service must preserve the original typed failure for its UI caller.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

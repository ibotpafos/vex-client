using System.ComponentModel;
using System.Security.Cryptography;
using Vex.Windows.App.Services;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

internal static class ServiceMaintenanceTests
{
    public static void Run()
    {
        var starts = 0;
        var diagnostics = 0;
        Task<int> Start(CancellationToken _) { starts++; return Task.FromResult(0); }
        Task<VpnServiceResponse> Healthy(CancellationToken _) { diagnostics++; return Task.FromResult(Response(true)); }
        var service = Create(Healthy, Start);
        Check(service.RepairAsync(default).GetAwaiter().GetResult().Success && starts == 0 && diagnostics == 1,
            "A verified running service should not be restarted.");

        starts = 0; diagnostics = 0;
        Task<VpnServiceResponse> Starting(CancellationToken _)
        {
            diagnostics++;
            return diagnostics < 3 ? Task.FromException<VpnServiceResponse>(new IOException("Starting")) : Task.FromResult(Response(true));
        }
        service = Create(Starting, Start);
        Check(service.RepairAsync(default).GetAwaiter().GetResult().Success && starts == 1 && diagnostics == 3,
            "Service start must wait for successful trusted diagnostics.");

        diagnostics = 0;
        service = Create(_ => { diagnostics++; return Task.FromResult(Response(false)); }, _ => Task.FromResult(1056));
        var result = service.RepairAsync(default).GetAwaiter().GetResult();
        Check(!result.Success && diagnostics == 11 && result.RecoveryUrl == "https://vexguard.app/downloads",
            "sc.exe already-running status must not imply success; diagnostics retries must remain bounded.");

        diagnostics = 0;
        service = Create(_ => { diagnostics++; return Task.FromResult(Response(false)); }, _ => Task.FromResult(1060));
        result = service.RepairAsync(default).GetAwaiter().GetResult();
        Check(!result.Success && diagnostics == 1 && result.RecoveryUrl is not null,
            "A missing service requires the verified installer instead of successful repair.");

        foreach (var error in new Exception[] { new CryptographicException("Runtime pin mismatch"), new UnauthorizedAccessException("Invalid service identity") })
        {
            starts = 0;
            service = error is CryptographicException
                ? Create(Healthy, Start, () => throw error)
                : Create(_ => Task.FromException<VpnServiceResponse>(error), Start);
            result = service.RepairAsync(default).GetAwaiter().GetResult();
            Check(!result.Success && starts == 0 && result.RecoveryUrl is not null,
                "Corrupt assets and unauthorized diagnostics must refuse elevation.");
        }

        service = Create(_ => Task.FromResult(Response(false)), _ => Task.FromException<int>(new Win32Exception(1223)));
        result = service.RepairAsync(default).GetAwaiter().GetResult();
        Check(!result.Success && result.RecoveryUrl is null, "User-cancelled UAC should remain a cancellable repair.");

        using var cancellation = new CancellationTokenSource();
        service = Create(_ => { cancellation.Cancel(); return Task.FromResult(Response(true)); }, Start);
        try
        {
            service.RepairAsync(cancellation.Token).GetAwaiter().GetResult();
            throw new InvalidOperationException("Late successful diagnostics ignored caller cancellation.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }

        using var ignoredCancellation = new CancellationTokenSource();
        service = Create(_ =>
        {
            ignoredCancellation.Cancel();
            return new TaskCompletionSource<VpnServiceResponse>().Task;
        }, Start);
        try
        {
            service.RepairAsync(ignoredCancellation.Token).WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
            throw new InvalidOperationException("An unresponsive diagnostics operation ignored caller cancellation.");
        }
        catch (OperationCanceledException) when (ignoredCancellation.IsCancellationRequested) { }

        var touched = false;
        service = Create(_ => { touched = true; return Task.FromResult(Response(true)); },
            _ => { touched = true; return Task.FromResult(0); }, () => touched = true, () => true);
        Check(!service.RepairAsync(default).GetAwaiter().GetResult().Success && !touched,
            "UI preview must not inspect runtime assets or start a system service.");
    }

    private static WindowsServiceMaintenanceService Create(Func<CancellationToken, Task<VpnServiceResponse>> diagnostics,
        Func<CancellationToken, Task<int>> start, Action? validate = null, Func<bool>? preview = null) =>
        new(diagnostics, start, validate ?? (() => { }), preview ?? (() => false), _ => Task.CompletedTask);

    private static VpnServiceResponse Response(bool success) =>
        new("maintenance-test", success, VpnConnectionSnapshot.Disconnected(), success ? null : "service_unavailable");

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

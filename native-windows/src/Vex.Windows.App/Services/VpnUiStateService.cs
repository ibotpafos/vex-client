using System.Security.Cryptography;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Services;

public sealed class VpnUiStateService
{
    private readonly Func<CancellationToken, Task<VpnServiceResponse>> _getDiagnostics;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _intentSync = new();
    private VpnConnectionSnapshot _snapshot = VpnConnectionSnapshot.Disconnected();
    private bool _connectionDesired;
    private bool _hasExplicitConnectionIntent;
    private volatile bool _shutdownComplete;

    public VpnUiStateService(
        Func<CancellationToken, Task<VpnServiceResponse>> getDiagnostics)
    {
        ArgumentNullException.ThrowIfNull(getDiagnostics);
        _getDiagnostics = getDiagnostics;
    }

    public event EventHandler? Changed;

    public event EventHandler? DesiredChanged;

    public VpnConnectionSnapshot Snapshot => Volatile.Read(ref _snapshot);

    public ulong ReceivedBytes => ToUnsigned(Snapshot.Diagnostics?.RxBytes);

    public ulong SentBytes => ToUnsigned(Snapshot.Diagnostics?.TxBytes);

    public bool ConnectionDesired
    {
        get { lock (_intentSync) return _connectionDesired; }
    }

    public bool HasExplicitConnectionIntent
    {
        get { lock (_intentSync) return _hasExplicitConnectionIntent; }
    }

    public async Task<VpnServiceResponse> RefreshAsync(
        CancellationToken cancellationToken) =>
        await RunAsync(
            _getDiagnostics,
            cancellationToken).ConfigureAwait(false);

    public Task<VpnServiceResponse> DisconnectIfUnwantedAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> disconnect,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(disconnect);
        return RunAsync(token =>
        {
            // A user can request a new connection while cleanup waits for the
            // operation gate. Honor the most recent intent before sending IPC.
            if (!HasExplicitConnectionIntent || ConnectionDesired ||
                !VpnRecoveryPolicy.RequiresDisconnect(Snapshot))
                return Task.FromResult(new VpnServiceResponse(
                    Guid.NewGuid().ToString("N"), true, Snapshot, null));
            return disconnect(token);
        }, cancellationToken);
    }

    public async Task<VpnServiceResponse> RunAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> operation,
        CancellationToken cancellationToken,
        bool recordCancellationFailure = true)
    {
        ArgumentNullException.ThrowIfNull(operation);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_shutdownComplete) throw new OperationCanceledException("VEX is shutting down.");
            var response = await operation(cancellationToken)
                .ConfigureAwait(false);
            Apply(response);
            if (!response.Success && VpnRecoveryPolicy.IsTerminalError(response.ErrorCode))
                MarkConnectionDesired(false);
            return response;
        }
        catch (Exception error) when (IsExpectedFailure(error))
        {
            // Record failures before releasing the gate. A caller reporting a
            // late poll failure must never overwrite a newer connect/disconnect.
            if (!_shutdownComplete && (error is not OperationCanceledException || recordCancellationFailure))
            {
                var code = error is NativeClientFlowException flow
                    ? flow.Code
                    : "vpn_service_unavailable";
                Apply(new VpnServiceResponse(Guid.NewGuid().ToString("N"), false,
                    VpnConnectionSnapshot.ClientFailure(Snapshot, code), code));
                if (VpnRecoveryPolicy.IsTerminalError(code)) MarkConnectionDesired(false);
            }
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    // Called under RunAsync's gate after shutdown has confirmed tunnel cleanup.
    // Prevent queued connects from starting between that response and closing UI.
    public void CompleteShutdown()
    {
        _shutdownComplete = true;
        MarkConnectionDesired(false);
    }

    public void MarkConnectionDesired(bool desired)
    {
        lock (_intentSync)
        {
            _hasExplicitConnectionIntent = true;
            _connectionDesired = desired && !_shutdownComplete;
        }
        DesiredChanged?.Invoke(this, EventArgs.Empty);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void RestoreConnectionDesired()
    {
        lock (_intentSync)
        {
            if (_hasExplicitConnectionIntent) return;
            _connectionDesired = true;
        }
        DesiredChanged?.Invoke(this, EventArgs.Empty);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Apply(VpnServiceResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        Volatile.Write(ref _snapshot, response.Snapshot with
        {
            Diagnostics = response.Diagnostics ?? response.Snapshot.Diagnostics,
        });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static ulong ToUnsigned(long? value) =>
        value is > 0
            ? (ulong)value.Value
            : 0;

    private static bool IsExpectedFailure(Exception error) => error is
        IOException or UnauthorizedAccessException or CryptographicException or
        HttpRequestException or InvalidOperationException or NativeClientFlowException or
        VexApiException or VpnIpcProtocolException or OperationCanceledException;
}

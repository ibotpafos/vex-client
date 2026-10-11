using System.Security.Cryptography;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;
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
    private long _intentVersion;
    private CancellationTokenSource? _connectionCancellation;
    private int _connectionCleanupCount;

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

    public long ConnectionIntentVersion
    {
        get { lock (_intentSync) return _intentVersion; }
    }

    public bool IsConnectionInFlight
    {
        get { lock (_intentSync) return _connectionCancellation is not null; }
    }

    public bool IsConnectionCleanupInFlight => Volatile.Read(ref _connectionCleanupCount) > 0;

    public async Task<VpnServiceResponse> RunConnectionAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> connect,
        CancellationToken cancellationToken,
        bool onlyWhenIdle = false)
    {
        ArgumentNullException.ThrowIfNull(connect);
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        CancellationTokenSource? previous;
        long intentVersion;
        lock (_intentSync)
        {
            if (onlyWhenIdle && !ServerPickerInteractionPolicy.CanSelect(
                    Snapshot.Phase, _connectionCancellation is not null, IsConnectionCleanupInFlight))
                throw new NativeClientFlowException("vpn_operation_in_progress");
            if (!_connectionDesired || _shutdownComplete)
                throw new OperationCanceledException("A connection is no longer requested.");
            // A server switch is a new intent even while Connected remains
            // desired. Background admission decisions must see its revision.
            intentVersion = ++_intentVersion;
            previous = _connectionCancellation;
            _connectionCancellation = connection;
        }
        Cancel(previous);
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            return await RunAsync(async token =>
            {
                try
                {
                    EnsureCurrentConnection(connection, intentVersion, token);
                    var response = await connect(token).ConfigureAwait(false);
                    // Closing an IPC read does not stop the privileged service.
                    // Never publish a late successful response after cancellation.
                    EnsureCurrentConnection(connection, intentVersion, token);
                    return response;
                }
                catch (Exception error) when (IsExpectedFailure(error))
                {
                    if (!IsCurrentConnection(connection, intentVersion))
                    {
                        if (!ConnectionDesired && !_shutdownComplete)
                            Apply(CleanupIncomplete());
                        throw new OperationCanceledException("The connection request was canceled.", error, token);
                    }
                    throw;
                }
            }, connection.Token, recordCancellationFailure: false).ConfigureAwait(false);
        }
        finally
        {
            lock (_intentSync)
            {
                if (ReferenceEquals(_connectionCancellation, connection))
                    _connectionCancellation = null;
            }
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task<VpnServiceResponse> CancelConnectionAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> disconnect,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(disconnect);
        Interlocked.Increment(ref _connectionCleanupCount);
        try
        {
            var intentVersion = ChangeConnectionIntent(false);
            using var cleanup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cleanup.CancelAfter(TimeSpan.FromSeconds(60));
            return await RunAsync(async token =>
            {
                lock (_intentSync)
                {
                    // A new connect may have been requested while cleanup waited.
                    if (_connectionDesired || _intentVersion != intentVersion)
                        return new VpnServiceResponse(Guid.NewGuid().ToString("N"), true, Snapshot, null);
                }
                try
                {
                    // Always send Disconnect, even when the last confirmed snapshot
                    // predates the service's in-flight Connect request.
                    var response = await disconnect(token).ConfigureAwait(false);
                    return response.Success && response.Snapshot.Phase == VpnConnectionPhase.Disconnected &&
                        !VpnRecoveryPolicy.RequiresDisconnect(response.Snapshot)
                        ? response
                        : CleanupIncomplete(response.Snapshot);
                }
                catch (Exception error) when (IsExpectedFailure(error))
                {
                    // Retain cleanup evidence so the background host can retry after
                    // an IPC timeout, including when no adapter was observed yet.
                    return CleanupIncomplete();
                }
            }, cleanup.Token).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Decrement(ref _connectionCleanupCount);
            Changed?.Invoke(this, EventArgs.Empty);
        }
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
            if (!response.Success && VpnFailurePresentation.IsTerminalError(response.ErrorCode))
                MarkConnectionDesired(false);
            return response;
        }
        catch (Exception error) when (IsExpectedFailure(error))
        {
            // Record failures before releasing the gate. A caller reporting a
            // late poll failure must never overwrite a newer connect/disconnect.
            if (!_shutdownComplete && (error is not OperationCanceledException || recordCancellationFailure ||
                VpnFailurePresentation.IsNetworkTimeout(error)))
            {
                var code = VpnFailurePresentation.CodeFromException(error);
                Apply(new VpnServiceResponse(Guid.NewGuid().ToString("N"), false,
                    VpnConnectionSnapshot.ClientFailure(Snapshot, code), code));
                if (VpnFailurePresentation.IsTerminalError(code)) MarkConnectionDesired(false);
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
        => ChangeConnectionIntent(desired);

    // Called under RunAsync's gate when background admission is revoked. User
    // intent can change before acquiring that gate, or on another UI thread.
    internal bool TryMarkConnectionUndesired(long expectedIntentVersion)
    {
        CancellationTokenSource? connection;
        lock (_intentSync)
        {
            if (_intentVersion != expectedIntentVersion) return false;
            _hasExplicitConnectionIntent = true;
            _connectionDesired = false;
            ++_intentVersion;
            connection = _connectionCancellation;
        }
        Cancel(connection);
        DesiredChanged?.Invoke(this, EventArgs.Empty);
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    private long ChangeConnectionIntent(bool desired)
    {
        CancellationTokenSource? connection;
        long version;
        lock (_intentSync)
        {
            _hasExplicitConnectionIntent = true;
            _connectionDesired = desired && !_shutdownComplete;
            version = ++_intentVersion;
            connection = !_connectionDesired ? _connectionCancellation : null;
        }
        Cancel(connection);
        DesiredChanged?.Invoke(this, EventArgs.Empty);
        Changed?.Invoke(this, EventArgs.Empty);
        return version;
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

    private bool IsCurrentConnection(CancellationTokenSource connection, long intentVersion)
    {
        lock (_intentSync)
            return _connectionDesired && !_shutdownComplete &&
                _intentVersion == intentVersion && ReferenceEquals(_connectionCancellation, connection);
    }

    private void EnsureCurrentConnection(CancellationTokenSource connection, long intentVersion,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsCurrentConnection(connection, intentVersion))
            throw new OperationCanceledException("A newer VPN intent replaced this connection.", cancellationToken);
    }

    private VpnServiceResponse CleanupIncomplete(VpnConnectionSnapshot? snapshot = null) =>
        new(Guid.NewGuid().ToString("N"), false,
            VpnConnectionSnapshot.ClientFailure(snapshot ?? Snapshot, "tunnel_cleanup_incomplete"),
            "tunnel_cleanup_incomplete");

    private static void Cancel(CancellationTokenSource? cancellation)
    {
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
    }

    private static bool IsExpectedFailure(Exception error) => error is
        IOException or UnauthorizedAccessException or CryptographicException or
        HttpRequestException or InvalidOperationException or NativeClientFlowException or
        VexApiException or VpnIpcProtocolException or OperationCanceledException;
}

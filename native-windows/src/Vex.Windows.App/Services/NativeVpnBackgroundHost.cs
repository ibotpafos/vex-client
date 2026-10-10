using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Threading.Channels;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Services;

/// <summary>Owns monitoring for the whole app, including hidden/tray operation.</summary>
public sealed class NativeVpnBackgroundHost : IDisposable, IAsyncDisposable
{
    private readonly AppServices _services;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Channel<bool> _wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        FullMode = BoundedChannelFullMode.DropWrite,
        SingleReader = true,
    });
    private readonly object _recoverySync = new();
    private CancellationTokenSource? _recoveryCancellation;
    private Task? _loop;
    private DateTimeOffset? _lastRecoveryAttempt;
    private DateTimeOffset? _lastDisconnectAttempt;
    private readonly VpnConnectionHealthTracker _connectionHealth = new();
    private DateTimeOffset? _lastDiagnosticsFlush;
    private DateTimeOffset? _lastEntitlementCheck;
    private bool _restored;
    private bool _disposed;

    public NativeVpnBackgroundHost(AppServices services) => _services = services;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_loop is not null) return;
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        _services.VpnUiState.DesiredChanged += OnDesiredChanged;
        _services.Preferences.Changed += OnDesiredChanged;
        _services.UpdateService.Changed += OnDesiredChanged;
        _loop = RunAsync(_lifetime.Token);
    }

    public void Wake() => _wake.Writer.TryWrite(true);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        _services.VpnUiState.DesiredChanged -= OnDesiredChanged;
        _services.Preferences.Changed -= OnDesiredChanged;
        _services.UpdateService.Changed -= OnDesiredChanged;
        _lifetime.Cancel();
        lock (_recoverySync) _recoveryCancellation?.Cancel();
        _wake.Writer.TryComplete();
    }

    public async ValueTask DisposeAsync()
    {
        Dispose();
        if (_loop is { } loop) await loop.ConfigureAwait(false);
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs args) => Wake();
    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs args) => Wake();
    private void OnDesiredChanged(object? sender, EventArgs args)
    {
        var update = _services.UpdateService.CurrentSnapshot;
        if (!_services.VpnUiState.ConnectionDesired ||
            !_services.Preferences.Current.AutoRecoveryEnabled ||
            update.UpdateAvailable && update.Required)
        {
            lock (_recoverySync) _recoveryCancellation?.Cancel();
        }
        Wake();
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(VpnRecoveryPolicy.PollInterval);
        var ticks = PumpTicksAsync(timer, cancellationToken);
        Wake();
        try
        {
            await foreach (var _ in _wake.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                try
                {
                    await CheckAsync(cancellationToken).ConfigureAwait(false);
                    await ValidateActiveEntitlementAsync(cancellationToken).ConfigureAwait(false);
                    await FlushDiagnosticsAsync(cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
                catch (Exception error) when (IsExpectedFailure(error))
                {
                    // Keep polling after a service restart or an unavailable network.
                    // VpnUiState records operation failures under its gate; applying
                    // here could overwrite a newer successful user operation.
                }
                catch (Exception error)
                {
                    System.Diagnostics.Debug.WriteLine($"VPN monitoring failed: {error.GetType().Name}");
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        finally
        {
            timer.Dispose();
            try { await ticks.ConfigureAwait(false); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        }
    }

    private async Task PumpTicksAsync(PeriodicTimer timer, CancellationToken cancellationToken)
    {
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false)) Wake();
    }

    private async Task FlushDiagnosticsAsync(CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        if (_services.Coordinator.CurrentStateAccess != ClientStateAccessKind.Available ||
            _lastDiagnosticsFlush is { } last && now - last < TimeSpan.FromMinutes(1)) return;
        _lastDiagnosticsFlush = now;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            await DiagnosticsQueueService.Current.FlushAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (IsExpectedFailure(error) && !cancellationToken.IsCancellationRequested)
        {
            // A diagnostic retry must never change VPN status.
        }
    }

    private async Task ValidateActiveEntitlementAsync(CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        if (_services.VpnUiState.Snapshot.Phase != VpnConnectionPhase.Connected ||
            _services.Coordinator.CurrentStateAccess != ClientStateAccessKind.Available ||
            _lastEntitlementCheck is { } last && now - last < TimeSpan.FromMinutes(1)) return;
        _lastEntitlementCheck = now;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            await _services.Coordinator.ValidateEntitlementAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (NativeClientFlowException error) when (VpnRecoveryPolicy.IsTerminalError(error.Code))
        {
            _services.VpnUiState.MarkConnectionDesired(false);
            await _services.VpnUiState.RunAsync(_services.VpnClient.DisconnectAsync,
                cancellationToken, recordCancellationFailure: false).ConfigureAwait(false);
        }
        catch (Exception error) when (IsExpectedFailure(error) && !cancellationToken.IsCancellationRequested)
        {
            // Temporary control-plane failures do not invalidate an admitted tunnel.
        }
    }

    private async Task CheckAsync(CancellationToken cancellationToken)
    {
        VpnServiceResponse status;
        using (var poll = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            poll.CancelAfter(TimeSpan.FromSeconds(15));
            status = await _services.VpnUiState.RefreshAsync(poll.Token).ConfigureAwait(false);
        }
        var snapshot = _services.VpnUiState.Snapshot;
        var now = DateTimeOffset.UtcNow;
        _connectionHealth.Observe(snapshot, now);
        var sessionAccess = _services.Coordinator.CurrentStateAccess;
        if (sessionAccess == ClientStateAccessKind.Missing &&
            VpnRecoveryPolicy.RequiresDisconnect(snapshot) &&
            (!_services.VpnUiState.HasExplicitConnectionIntent || _services.VpnUiState.ConnectionDesired))
        {
            // A persisted session clear is logout evidence even after restarting
            // the app following an unavailable privileged service.
            _services.VpnUiState.MarkConnectionDesired(false);
        }
        if (!_restored && status.Success)
        {
            _restored = true;
            if (!_services.VpnUiState.HasExplicitConnectionIntent &&
                snapshot.Phase == VpnConnectionPhase.Connected &&
                sessionAccess is ClientStateAccessKind.Available or ClientStateAccessKind.Locked)
            {
                _services.VpnUiState.RestoreConnectionDesired();
            }
        }

        if (VpnRecoveryPolicy.ShouldEnforceDisconnect(snapshot,
            _services.VpnUiState.HasExplicitConnectionIntent,
            _services.VpnUiState.ConnectionDesired, now, _lastDisconnectAttempt))
        {
            await EnforceDisconnectAsync(cancellationToken).ConfigureAwait(false);
            return;
        }

        if (!VpnRecoveryPolicy.ShouldRecover(snapshot,
            _services.VpnUiState.ConnectionDesired,
            _services.Preferences.Current.AutoRecoveryEnabled,
            sessionAccess == ClientStateAccessKind.Available,
            now, _connectionHealth.ConnectedSince, _lastRecoveryAttempt)) return;
        var update = _services.UpdateService.CurrentSnapshot;
        if (update.UpdateAvailable && update.Required) return;

        using var recovery = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        recovery.CancelAfter(TimeSpan.FromSeconds(100));
        lock (_recoverySync) _recoveryCancellation = recovery;
        try
        {
            await _services.VpnUiState.RunAsync(async token =>
            {
                // The user may have pressed Disconnect while we waited for the gate.
                var current = _services.VpnUiState.Snapshot;
                var currentTime = DateTimeOffset.UtcNow;
                _connectionHealth.Observe(current, currentTime);
                var preferences = _services.Preferences.Current;
                var latestUpdate = _services.UpdateService.CurrentSnapshot;
                if (!VpnRecoveryPolicy.ShouldRecover(current,
                        _services.VpnUiState.ConnectionDesired,
                        preferences.AutoRecoveryEnabled,
                        _services.Coordinator.CurrentStateAccess == ClientStateAccessKind.Available,
                        currentTime, _connectionHealth.ConnectedSince, _lastRecoveryAttempt) ||
                    latestUpdate.UpdateAvailable && latestUpdate.Required)
                    return new VpnServiceResponse(Guid.NewGuid().ToString("N"), true, _services.VpnUiState.Snapshot, null);
                token.ThrowIfCancellationRequested();
                _lastRecoveryAttempt = currentTime;
                return await _services.ProductParity.RecoverAsync(
                    _services.Coordinator, preferences,
                    current, token).ConfigureAwait(false);
            }, recovery.Token, recordCancellationFailure: false).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
        finally
        {
            lock (_recoverySync) _recoveryCancellation = null;
        }
    }

    private async Task EnforceDisconnectAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(60));
        var attempted = false;
        try
        {
            await _services.VpnUiState.DisconnectIfUnwantedAsync(async token =>
            {
                attempted = true;
                _lastDisconnectAttempt = DateTimeOffset.UtcNow;
                return await _services.VpnClient.DisconnectAsync(token).ConfigureAwait(false);
            }, timeout.Token).ConfigureAwait(false);
        }
        finally
        {
            // Back off after completion as well as after a failed/slow attempt.
            // Cleanup remains permitted with a missing/locked session or update.
            if (attempted) _lastDisconnectAttempt = DateTimeOffset.UtcNow;
        }
    }

    private static bool IsExpectedFailure(Exception error) => error is
        IOException or UnauthorizedAccessException or CryptographicException or
        HttpRequestException or InvalidOperationException or NativeClientFlowException or
        VexApiException or VpnIpcProtocolException or OperationCanceledException;
}

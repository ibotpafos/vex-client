using System.Threading.Channels;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

public sealed class NativeProfileWarmupHost : IDisposable
{
    private readonly AppServices _services;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Channel<bool> _wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        FullMode = BoundedChannelFullMode.DropWrite,
        SingleReader = true,
    });
    private Task? _loop;
    private long _nextAttemptTicks;
    private bool _disposed;

    public NativeProfileWarmupHost(AppServices services) => _services = services;

    public void Start()
    {
        if (_disposed || _loop is not null || UiPreviewContext.IsEnabled) return;
        _services.Auth.StateChanged += OnChanged;
        _services.Coordinator.SessionChanged += OnChanged;
        _services.Coordinator.ProfileScopeChanged += OnChanged;
        _services.Preferences.Changed += OnChanged;
        _services.VpnUiState.DesiredChanged += OnChanged;
        _services.VpnUiState.Changed += OnVpnSnapshotChanged;
        _services.UpdateService.Changed += OnChanged;
        _loop = RunAsync(_lifetime.Token);
        _wake.Writer.TryWrite(true);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _services.Auth.StateChanged -= OnChanged;
        _services.Coordinator.SessionChanged -= OnChanged;
        _services.Coordinator.ProfileScopeChanged -= OnChanged;
        _services.Preferences.Changed -= OnChanged;
        _services.VpnUiState.DesiredChanged -= OnChanged;
        _services.VpnUiState.Changed -= OnVpnSnapshotChanged;
        _services.UpdateService.Changed -= OnChanged;
        _services.Coordinator.CancelProfileWarmup();
        _lifetime.Cancel();
        _wake.Writer.TryComplete();
    }

    private void OnChanged(object? sender, EventArgs args)
    {
        _services.Coordinator.CancelProfileWarmup();
        Interlocked.Exchange(ref _nextAttemptTicks, 0);
        _wake.Writer.TryWrite(true);
    }

    private void OnVpnSnapshotChanged(object? sender, EventArgs args) =>
        _wake.Writer.TryWrite(true);

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
        var ticks = PumpTicksAsync(timer, cancellationToken);
        try
        {
            await foreach (var _ in _wake.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                var now = DateTimeOffset.UtcNow;
                var snapshot = _services.VpnUiState.Snapshot;
                var update = _services.UpdateService.CurrentSnapshot;
                if (now.UtcTicks < Interlocked.Read(ref _nextAttemptTicks) ||
                    snapshot.Phase != VpnConnectionPhase.Disconnected || snapshot.ErrorCode is not null || snapshot.Sequence <= 0 ||
                    _services.Coordinator.CurrentStateAccess != ClientStateAccessKind.Available ||
                    _services.VpnUiState.ConnectionDesired || _services.VpnUiState.IsConnectionInFlight ||
                    _services.VpnUiState.IsConnectionCleanupInFlight || VpnRecoveryPolicy.RequiresDisconnect(snapshot) ||
                    update.UpdateAvailable && update.Required) continue;
                Interlocked.Exchange(ref _nextAttemptTicks, now.AddMinutes(2).UtcTicks);
                try
                {
                    var preferences = _services.Preferences.Current;
                    await _services.Coordinator.WarmProfileAsync(preferences.AutoServerEnabled
                        ? null : preferences.SelectedLocationId,
                        preferences.SmartRoutingEnabled ? "split" : "full", null,
                        cancellationToken).ConfigureAwait(false);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or
                    System.Security.Cryptography.CryptographicException or InvalidOperationException or
                    System.Text.Json.JsonException or OperationCanceledException) { }
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
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            _wake.Writer.TryWrite(true);
    }
}

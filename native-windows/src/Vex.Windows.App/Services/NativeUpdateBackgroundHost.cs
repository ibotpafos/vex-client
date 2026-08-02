using Vex.Windows.Core.Updates;

namespace Vex.Windows.App.Services;

public sealed class NativeUpdateBackgroundHost : IDisposable
{
    private readonly NativeUpdateService _updateService;
    private readonly NativeClientPreferencesStore _preferences;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _checkGate = new(1, 1);
    private Task? _loopTask;
    private bool _disposed;

    public NativeUpdateBackgroundHost(
        NativeUpdateService updateService,
        NativeClientPreferencesStore preferences)
    {
        ArgumentNullException.ThrowIfNull(updateService);
        ArgumentNullException.ThrowIfNull(preferences);
        _updateService = updateService;
        _preferences = preferences;
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _loopTask ??= RunAsync(_lifetime.Token);
    }

    public async Task<NativeUpdateSnapshot> CheckNowAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _checkGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await _updateService.RefreshAsync(cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _checkGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetime.Cancel();
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(
                NativeUpdateCheckPolicy.StartupDelay,
                cancellationToken).ConfigureAwait(false);
            while (!cancellationToken.IsCancellationRequested)
            {
                var succeeded = true;
                if (_preferences.Current.AutoUpdatesEnabled)
                {
                    var snapshot = await CheckNowAsync(cancellationToken)
                        .ConfigureAwait(false);
                    succeeded = snapshot.State is not "error" and not "disabled";
                }

                await Task.Delay(
                    NativeUpdateCheckPolicy.NextDelay(succeeded),
                    cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
        }
    }

}

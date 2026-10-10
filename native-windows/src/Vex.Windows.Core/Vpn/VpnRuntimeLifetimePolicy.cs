using System.Text;

namespace Vex.Windows.Core.Vpn;

public interface IVpnRuntimeLifetime
{
    void BeginShutdown();
    Task QuiesceAsync(CancellationToken cancellationToken);
}

public static class VpnRuntimeLifetimePolicy
{
    public static readonly TimeSpan PipeShutdownTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan QuiesceTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan CleanupTimeout = TimeSpan.FromSeconds(40);
    public static readonly TimeSpan HostShutdownTimeout = TimeSpan.FromSeconds(75);

    // Restoration is permitted only after the vendor tunnel has definitely
    // stopped. A failure at any stage retains the journal and authorization.
    public static async Task StopAndRestoreAsync(
        Func<CancellationToken, Task> stopTunnel,
        Func<CancellationToken, Task> restoreNetwork,
        Func<bool> cleanupVerified,
        Action releaseAuthorization,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await stopTunnel(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        await restoreNetwork(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (!cleanupVerified())
        {
            throw new VpnTunnelException("tunnel_cleanup_incomplete");
        }
        releaseAuthorization();
    }
}

// A separate, fail-closed marker distinguishes a retained authorization lease
// from the user's desired connection state after a failed cleanup and restart.
public sealed class VpnDisconnectIntent(string path)
{
    private readonly object _gate = new();
    private long _revision;

    public bool IsRecorded
    {
        get
        {
            try { _ = File.GetAttributes(path); return true; }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }
        }
    }

    public long Record(Action? prepareStorage = null)
    {
        lock (_gate)
        {
            // Invalidate an in-flight connect even if storage subsequently fails.
            var revision = ++_revision;
            prepareStorage?.Invoke();
            if (IsRecorded) { return revision; }
            var temporaryPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var stream = new FileStream(temporaryPath, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    stream.Write(Encoding.UTF8.GetBytes("disconnected\n"));
                    stream.Flush(flushToDisk: true);
                }
                File.Move(temporaryPath, path, overwrite: true);
                return revision;
            }
            finally
            {
                if (File.Exists(temporaryPath)) { File.Delete(temporaryPath); }
            }
        }
    }

    public void ClearForVerifiedConnection(long connectionRevision)
    {
        lock (_gate)
        {
            if (connectionRevision != _revision)
            {
                throw new VpnTunnelException("tunnel_connection_superseded");
            }
            File.Delete(path);
        }
    }
}

// Track every automatic callback, including network-change work queued before
// shutdown. Cancelling a timer alone would leave such callbacks able to restart
// the tunnel while the host is restoring the firewall.
public sealed class VpnRuntimeBackgroundWork
{
    private readonly object _gate = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly HashSet<Task> _tasks = [];
    private bool _stopping;

    public CancellationToken Token => _cancellation.Token;

    public bool IsStopping { get { lock (_gate) { return _stopping; } } }

    public bool Run(Func<CancellationToken, Task> callback)
    {
        lock (_gate)
        {
            if (_stopping) { return false; }
            var task = Task.Run(async () =>
            {
                try { await callback(_cancellation.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (_cancellation.IsCancellationRequested) { }
            });
            _tasks.Add(task);
            _ = task.ContinueWith(completed =>
            {
                // Observe faults even if a callback finishes before shutdown.
                _ = completed.Exception;
                lock (_gate) { _tasks.Remove(completed); }
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            return true;
        }
    }

    public void Stop()
    {
        lock (_gate) { _stopping = true; }
        _cancellation.Cancel();
    }

    public Task DrainAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (!_stopping) { throw new InvalidOperationException("Stop background work before draining it."); }
            return Task.WhenAll(_tasks.ToArray()).WaitAsync(cancellationToken);
        }
    }
}

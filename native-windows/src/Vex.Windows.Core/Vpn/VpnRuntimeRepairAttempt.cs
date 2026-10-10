namespace Vex.Windows.Core.Vpn;

// A disconnect supersedes a network repair independently of the runtime gate.
// The same fence orders the synchronous SCM start against that supersession.
public sealed class VpnRuntimeRepairAttempt : IDisposable
{
    private readonly object _gate = new();
    private readonly CancellationTokenSource _cancellation;
    private bool _disposed;

    public VpnRuntimeRepairAttempt(CancellationToken cancellationToken)
    {
        _cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Token = _cancellation.Token;
    }

    public CancellationToken Token { get; }

    public void Supersede()
    {
        lock (_gate)
        {
            if (!_disposed) { _cancellation.Cancel(); }
        }
    }

    public void StartIfCurrent(Action startTunnel)
    {
        ArgumentNullException.ThrowIfNull(startTunnel);
        lock (_gate)
        {
            Token.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(_disposed, this);
            startTunnel();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _cancellation.Cancel();
            _cancellation.Dispose();
        }
    }
}

namespace Vex.Windows.Core.Vpn;

// Each operation owns its deadline. Replacing a persisted lease cannot make an
// older expiry timer cancel the operation admitted by the replacement lease.
public sealed class VpnAuthorizationDeadline : IDisposable
{
    private readonly TimeProvider _timeProvider;
    private readonly CancellationTokenSource _deadline;
    private readonly CancellationTokenSource _operation;

    public VpnAuthorizationDeadline(DateTimeOffset expiresAt,
        CancellationToken cancellationToken, TimeProvider? timeProvider = null)
    {
        ExpiresAt = expiresAt;
        _timeProvider = timeProvider ?? TimeProvider.System;
        var remaining = expiresAt - _timeProvider.GetUtcNow();
        if (remaining <= TimeSpan.Zero)
        {
            _deadline = new CancellationTokenSource();
            _deadline.Cancel();
        }
        else
        {
            _deadline = new CancellationTokenSource(remaining, _timeProvider);
        }
        _operation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _deadline.Token);
    }

    public DateTimeOffset ExpiresAt { get; }
    public CancellationToken Token => _operation.Token;
    public bool IsExpired => _timeProvider.GetUtcNow() >= ExpiresAt;

    public void ThrowIfExpired()
    {
        // Check the actual clock as well as the timer: a delayed timer callback
        // must never let a synchronous start or Connected commit admit expiry.
        if (IsExpired) { throw new VpnTunnelException("profile_expired"); }
    }

    public void Dispose()
    {
        _operation.Dispose();
        _deadline.Dispose();
    }
}

using Vex.Windows.Core.Vpn;

internal static class VpnAuthorizationDeadlineTests
{
    public static readonly (string Name, Action Run)[] All =
    [
        ("Authorization expiry cancels a connect waiting for the runtime gate", ExpiryCancelsGateWait),
        ("Authorization expiry interrupts repair handshake and fences its restart", ExpiryCancelsRepair),
        ("Clock expiry rejects start and Connected admission even before its timer runs", ExpiryGuardDoesNotDependOnTimer),
        ("An old authorization timer cannot cancel a renewed operation", RenewalHasIndependentDeadline),
        ("Caller cancellation remains distinct from authorization expiry", CallerCancellationIsPreserved),
        ("An already expired authorization starts canceled and is never admitted", AlreadyExpiredFailsClosed),
        ("Expired operation cancellation leaves bounded ordered cleanup usable", ExpiredOperationDoesNotCancelCleanup),
    ];

    private static void ExpiryCancelsGateWait() => ExpiryCancelsGateWaitAsync().GetAwaiter().GetResult();

    private static async Task ExpiryCancelsGateWaitAsync()
    {
        var clock = new ControlledClock();
        using var lifetime = new CancellationTokenSource();
        using var authorization = new VpnAuthorizationDeadline(clock.GetUtcNow().AddSeconds(15), lifetime.Token, clock);
        using var gate = new SemaphoreSlim(0, 1);
        var waiting = gate.WaitAsync(authorization.Token);
        clock.Advance(TimeSpan.FromSeconds(15));
        await CanceledAsync(waiting).ConfigureAwait(false);
        Require(authorization.IsExpired && authorization.Token.IsCancellationRequested &&
            !lifetime.IsCancellationRequested && gate.CurrentCount == 0,
            "Expiry waited for the operation gate or canceled service lifetime.");
    }

    private static void ExpiryCancelsRepair() => ExpiryCancelsRepairAsync().GetAwaiter().GetResult();

    private static async Task ExpiryCancelsRepairAsync()
    {
        var clock = new ControlledClock();
        using var authorization = new VpnAuthorizationDeadline(clock.GetUtcNow().AddSeconds(15), CancellationToken.None, clock);
        using var repair = new VpnRuntimeRepairAttempt(authorization.Token);
        var handshake = Task.Delay(Timeout.InfiniteTimeSpan, repair.Token);
        clock.Advance(TimeSpan.FromSeconds(15));
        await CanceledAsync(handshake).ConfigureAwait(false);
        var starts = 0;
        await CanceledAsync(Task.Run(() => repair.StartIfCurrent(() => starts++))).ConfigureAwait(false);
        Require(starts == 0, "An expired repair restarted its vendor.");
    }

    private static void ExpiryGuardDoesNotDependOnTimer()
    {
        var clock = new ControlledClock();
        using var authorization = new VpnAuthorizationDeadline(clock.GetUtcNow().AddSeconds(15), CancellationToken.None, clock);
        clock.Advance(TimeSpan.FromSeconds(15), invokeTimers: false);
        Require(!authorization.Token.IsCancellationRequested, "The delayed-timer fixture ran its timer.");
        RejectExpired(authorization.ThrowIfExpired);
        Require(authorization.IsExpired, "Clock expiry was dependent on timer dispatch.");
    }

    private static void RenewalHasIndependentDeadline()
    {
        var clock = new ControlledClock();
        using var lifetime = new CancellationTokenSource();
        using var oldLease = new VpnAuthorizationDeadline(clock.GetUtcNow().AddSeconds(15), lifetime.Token, clock);
        using var renewedLease = new VpnAuthorizationDeadline(clock.GetUtcNow().AddMinutes(10), lifetime.Token, clock);
        clock.Advance(TimeSpan.FromSeconds(15));
        Require(oldLease.Token.IsCancellationRequested && !renewedLease.Token.IsCancellationRequested &&
            !lifetime.IsCancellationRequested, "The old lease canceled its replacement or the runtime.");
        oldLease.Dispose();
        renewedLease.ThrowIfExpired();
        using var repair = new VpnRuntimeRepairAttempt(renewedLease.Token);
        var starts = 0;
        repair.StartIfCurrent(() => starts++);
        Require(starts == 1 && !renewedLease.Token.IsCancellationRequested,
            "Disposing an old lease poisoned renewed repair.");
    }

    private static void CallerCancellationIsPreserved() => CallerCancellationIsPreservedAsync().GetAwaiter().GetResult();

    private static async Task CallerCancellationIsPreservedAsync()
    {
        var clock = new ControlledClock();
        using var caller = new CancellationTokenSource();
        using var authorization = new VpnAuthorizationDeadline(clock.GetUtcNow().AddMinutes(10), caller.Token, clock);
        var waiting = Task.Delay(Timeout.InfiniteTimeSpan, authorization.Token);
        caller.Cancel();
        await CanceledAsync(waiting).ConfigureAwait(false);
        authorization.ThrowIfExpired();
        Require(!authorization.IsExpired, "Caller cancellation was misclassified as profile_expired.");
    }

    private static void AlreadyExpiredFailsClosed()
    {
        var clock = new ControlledClock();
        foreach (var expiry in new[] { clock.GetUtcNow(), clock.GetUtcNow().AddTicks(-1) })
        {
            using var authorization = new VpnAuthorizationDeadline(expiry, CancellationToken.None, clock);
            Require(authorization.Token.IsCancellationRequested, "An expired authorization began uncanceled.");
            RejectExpired(authorization.ThrowIfExpired);
        }
    }

    private static void ExpiredOperationDoesNotCancelCleanup() => ExpiredOperationDoesNotCancelCleanupAsync().GetAwaiter().GetResult();

    private static async Task ExpiredOperationDoesNotCancelCleanupAsync()
    {
        var clock = new ControlledClock();
        using var authorization = new VpnAuthorizationDeadline(clock.GetUtcNow().AddSeconds(15), CancellationToken.None, clock);
        clock.Advance(TimeSpan.FromSeconds(15));
        using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var events = new List<string>();
        await VpnRuntimeLifetimePolicy.StopAndRestoreAsync(
            token => { token.ThrowIfCancellationRequested(); events.Add("stop"); return Task.CompletedTask; },
            token => { token.ThrowIfCancellationRequested(); events.Add("restore"); return Task.CompletedTask; },
            () => { events.Add("verify"); return true; },
            () => events.Add("release"), cleanup.Token).ConfigureAwait(false);
        Require(authorization.Token.IsCancellationRequested && !cleanup.IsCancellationRequested &&
            events.SequenceEqual(["stop", "restore", "verify", "release"]),
            "Expired operation canceled cleanup or bypassed confirmed-stop ordering.");
    }

    private static async Task CanceledAsync(Task task)
    {
        using var bounded = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try { await task.WaitAsync(bounded.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!bounded.IsCancellationRequested) { return; }
        throw new InvalidOperationException("Authorization did not cancel the blocked operation before its test deadline.");
    }

    private static void RejectExpired(Action action)
    {
        try { action(); }
        catch (VpnTunnelException error) when (error.Code == "profile_expired") { return; }
        throw new InvalidOperationException("Expired authorization did not report profile_expired.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    // This clock controls the BCL cancellation timer used by the production
    // deadline primitive. It substitutes no expiry or cancellation algorithm.
    private sealed class ControlledClock : TimeProvider
    {
        private DateTimeOffset _now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
        private readonly List<ControlledTimer> _timers = [];
        public override DateTimeOffset GetUtcNow() => _now;

        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new ControlledTimer(this, callback, state);
            _timers.Add(timer);
            timer.Change(dueTime, period);
            return timer;
        }

        public void Advance(TimeSpan elapsed, bool invokeTimers = true)
        {
            _now += elapsed;
            if (invokeTimers)
            {
                foreach (var timer in _timers.ToArray()) { timer.InvokeDue(); }
            }
        }

        private sealed class ControlledTimer(ControlledClock clock, TimerCallback callback, object? state) : ITimer
        {
            private DateTimeOffset? _due;
            private bool _disposed;

            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                if (_disposed) { return false; }
                if (period != Timeout.InfiniteTimeSpan) { throw new InvalidOperationException("Only one-shot expiry timers are expected."); }
                _due = dueTime == Timeout.InfiniteTimeSpan ? null : clock.GetUtcNow() + dueTime;
                return true;
            }

            public void InvokeDue()
            {
                if (!_disposed && _due is not null && _due <= clock.GetUtcNow())
                {
                    _due = null;
                    callback(state);
                }
            }

            public void Dispose() { _disposed = true; }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}

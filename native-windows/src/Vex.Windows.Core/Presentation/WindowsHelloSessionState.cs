namespace Vex.Windows.Core.Presentation;

public sealed record WindowsHelloSessionSnapshot(bool IsRequired, bool IsUnlocked);

/// <summary>Keeps the visible Hello setting consistent with its durable preference.</summary>
public sealed class WindowsHelloSessionState
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WindowsHelloSessionSnapshot _snapshot;

    public WindowsHelloSessionState(bool isRequired) =>
        _snapshot = new(isRequired, !isRequired);

    public WindowsHelloSessionSnapshot Snapshot => Volatile.Read(ref _snapshot);

    public async Task SetRequiredAsync(bool required,
        Func<CancellationToken, Task> verify,
        Action<bool, CancellationToken> persist,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(verify);
        ArgumentNullException.ThrowIfNull(persist);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (required || Snapshot.IsRequired)
                await verify(cancellationToken).WaitAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            // Persist is the commit boundary. A cancelled or failed write must
            // leave both the setting and the current lock state unchanged.
            persist(required, cancellationToken);
            Volatile.Write(ref _snapshot, new(required, IsUnlocked: true));
        }
        finally { _gate.Release(); }
    }

    public async Task UnlockAsync(Func<CancellationToken, Task> verify,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(verify);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Snapshot.IsRequired)
                await verify(cancellationToken).WaitAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            SetUnlocked(true);
        }
        finally { _gate.Release(); }
    }

    public void SessionSaved() => SetUnlocked(true);

    public void SessionCleared() => SetUnlocked(!Snapshot.IsRequired);

    private void SetUnlocked(bool unlocked)
    {
        WindowsHelloSessionSnapshot previous;
        WindowsHelloSessionSnapshot replacement;
        do
        {
            previous = Snapshot;
            replacement = previous with { IsUnlocked = unlocked };
        }
        while (!ReferenceEquals(Interlocked.CompareExchange(ref _snapshot, replacement, previous), previous));
    }
}

using System.Security.Cryptography;
using System.Text;
using Vex.Windows.Core.Presentation;

internal static class WindowsHelloSessionTests
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await SuccessfulTransitionsPersistBeforeVisibilityAsync();
        await FailedWritesPreserveVisibleAndDurableStateAsync();
        await FailedVerificationPreservesStateAsync();
        await CancelledLatePromptCannotChangeStateAsync("enable");
        await CancelledLatePromptCannotChangeStateAsync("disable");
        await CancelledLatePromptCannotChangeStateAsync("unlock");
        await CancelledPersistenceCannotChangeStateAsync();
        VerifyAtomicProtectedWrites();
    }

    private static async Task SuccessfulTransitionsPersistBeforeVisibilityAsync()
    {
        var state = new WindowsHelloSessionState(false);
        var persisted = false;
        var promptCalls = 0;
        Task Verify(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            promptCalls++;
            return Task.CompletedTask;
        }
        void Persist(bool required, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Require(state.Snapshot.IsRequired == persisted,
                "The visible Hello preference changed before the durable commit.");
            persisted = required;
        }

        await state.SetRequiredAsync(true, Verify, Persist, CancellationToken.None);
        Require(persisted && state.Snapshot is { IsRequired: true, IsUnlocked: true },
            "Verified Hello enable did not persist and unlock the current session.");
        var restarted = new WindowsHelloSessionState(persisted);
        Require(restarted.Snapshot is { IsRequired: true, IsUnlocked: false },
            "A restart did not lock the enabled Hello session.");
        await restarted.UnlockAsync(Verify, CancellationToken.None);
        Require(restarted.Snapshot.IsUnlocked && persisted,
            "Unlock changed the durable Hello preference or left the session locked.");
        restarted.SessionCleared();
        Require(!restarted.Snapshot.IsUnlocked && restarted.Snapshot.IsRequired,
            "Sign-out weakened the durable Hello setting.");
        restarted.SessionSaved();
        Require(restarted.Snapshot.IsUnlocked && restarted.Snapshot.IsRequired,
            "Saving a newly authenticated session did not unlock that process.");
        await state.SetRequiredAsync(false, Verify, Persist, CancellationToken.None);
        Require(!persisted && state.Snapshot is { IsRequired: false, IsUnlocked: true } && promptCalls == 3,
            "Disabling an enabled Hello preference did not verify and persist it.");
        var disabledRestart = new WindowsHelloSessionState(persisted);
        Require(disabledRestart.Snapshot.IsUnlocked, "A disabled preference locked a restarted session.");
    }

    private static async Task FailedWritesPreserveVisibleAndDurableStateAsync()
    {
        foreach (var required in new[] { false, true })
        foreach (var error in new Exception[] { new IOException("Disk full"),
            new UnauthorizedAccessException("Write denied"), new CryptographicException("Protection failed") })
        {
            var persisted = required;
            var state = new WindowsHelloSessionState(required);
            var before = state.Snapshot;
            try
            {
                await state.SetRequiredAsync(!required, _ => Task.CompletedTask,
                    (_, _) => throw error, CancellationToken.None);
                throw new InvalidOperationException("A failed protected preference write was reported as success.");
            }
            catch (Exception actual) when (ReferenceEquals(actual, error)) { }
            Require(state.Snapshot == before && new WindowsHelloSessionState(persisted).Snapshot.IsRequired == required,
                "A failed Hello preference write changed visible state or the next restart's setting.");
            await state.SetRequiredAsync(!required, _ => Task.CompletedTask,
                (value, _) => persisted = value, CancellationToken.None).WaitAsync(Deadline);
            Require(state.Snapshot.IsRequired == persisted && persisted != required,
                "A failed write retained the operation gate or prevented a later successful change.");
        }
    }

    private static async Task FailedVerificationPreservesStateAsync()
    {
        var state = new WindowsHelloSessionState(true);
        var persisted = false;
        var rejected = new InvalidOperationException("Hello was cancelled or unavailable.");
        try
        {
            await state.SetRequiredAsync(false, _ => Task.FromException(rejected),
                (_, _) => persisted = true, CancellationToken.None);
            throw new InvalidOperationException("A rejected Hello prompt changed the preference.");
        }
        catch (InvalidOperationException error) when (ReferenceEquals(error, rejected)) { }
        Require(!persisted && state.Snapshot is { IsRequired: true, IsUnlocked: false },
            "A rejected verification persisted or unlocked the protected session.");
    }

    private static async Task CancelledLatePromptCannotChangeStateAsync(string operation)
    {
        var required = operation != "enable";
        var state = new WindowsHelloSessionState(required);
        var before = state.Snapshot;
        var prompt = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var persisted = required;
        var writes = 0;
        using var cancellation = new CancellationTokenSource();
        Task Verify(CancellationToken token)
        {
            started.TrySetResult();
            return prompt.Task; // Models a WinRT prompt that finishes after caller cancellation.
        }
        void Persist(bool value, CancellationToken token)
        {
            writes++;
            persisted = value;
        }
        var attempt = operation == "unlock"
            ? state.UnlockAsync(Verify, cancellation.Token)
            : state.SetRequiredAsync(!required, Verify, Persist, cancellation.Token);
        await started.Task.WaitAsync(Deadline);
        cancellation.Cancel();
        await ExpectCancelledAsync(attempt);
        Require(writes == 0 && persisted == required && state.Snapshot == before,
            $"Cancelled {operation} changed the preference or unlocked the session.");
        prompt.TrySetResult();
        await prompt.Task.WaitAsync(Deadline);
        await state.UnlockAsync(_ => Task.CompletedTask, CancellationToken.None).WaitAsync(Deadline);
        Require(state.Snapshot.IsRequired == required && writes == 0,
            $"Late {operation} verification changed the setting or kept the gate blocked.");
    }

    private static async Task CancelledPersistenceCannotChangeStateAsync()
    {
        var state = new WindowsHelloSessionState(false);
        using var cancellation = new CancellationTokenSource();
        var attempt = state.SetRequiredAsync(true, _ => Task.CompletedTask, (_, token) =>
        {
            cancellation.Cancel();
            token.ThrowIfCancellationRequested();
        }, cancellation.Token);
        await ExpectCancelledAsync(attempt);
        Require(!state.Snapshot.IsRequired && state.Snapshot.IsUnlocked,
            "Cancellation before durable replacement changed the visible Hello setting.");
    }

    private static void VerifyAtomicProtectedWrites()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-hello-write-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "windows-hello.bin");
            var oldValue = Encoding.UTF8.GetBytes("old protected preference");
            var newValue = Encoding.UTF8.GetBytes("new protected preference");
            File.WriteAllBytes(path, oldValue);
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();
            try
            {
                ProtectedStateFileWriter.Write(path, newValue, cancellation.Token);
                throw new InvalidOperationException("A cancelled atomic write completed.");
            }
            catch (OperationCanceledException) { }
            Require(File.ReadAllBytes(path).SequenceEqual(oldValue),
                "Cancellation truncated the previously protected Hello preference.");
            ProtectedStateFileWriter.Write(path, newValue);
            Require(File.ReadAllBytes(path).SequenceEqual(newValue),
                "Atomic replacement did not commit the full protected preference.");
            var unavailablePath = Path.Combine(directory, "not-a-file.bin");
            Directory.CreateDirectory(unavailablePath);
            try
            {
                ProtectedStateFileWriter.Write(unavailablePath, newValue);
                throw new InvalidOperationException("An impossible protected-file replacement reported success.");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            Require(Directory.Exists(unavailablePath) &&
                Directory.GetFiles(directory, "*.new-*").Length == 0 &&
                File.ReadAllBytes(path).SequenceEqual(newValue),
                "A failed replacement damaged prior state or leaked its temporary file.");
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static async Task ExpectCancelledAsync(Task task)
    {
        try
        {
            await task.WaitAsync(Deadline);
            throw new InvalidOperationException("The cancelled Hello operation completed.");
        }
        catch (OperationCanceledException) { }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

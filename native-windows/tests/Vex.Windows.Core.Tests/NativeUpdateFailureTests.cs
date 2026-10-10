using System.Security.Cryptography;
using System.Text.Json;
using Vex.Windows.Core.Updates;

internal static class NativeUpdateFailureTests
{
    public static void Run()
    {
        foreach (var error in new Exception[]
        {
            new CryptographicException("Protected rollback state could not be written."),
            new UnauthorizedAccessException("Update state is read-only."),
            new JsonException("Pinned keyring is malformed."),
            new FormatException("Pinned public key is malformed."),
            new HttpRequestException("Offline"),
            new TaskCanceledException("Request deadline"),
        })
        {
            var calls = 0;
            Task<bool> Check(CancellationToken _)
            {
                calls++;
                return calls == 1 ? Task.FromException<bool>(error) : Task.FromResult(true);
            }
            var failed = NativeUpdateFailurePolicy.CheckSafelyAsync(Check, CancellationToken.None)
                .GetAwaiter().GetResult();
            if (failed || NativeUpdateCheckPolicy.NextDelay(failed) != TimeSpan.FromMinutes(15))
                throw new InvalidOperationException("Update failure did not retain the bounded retry.");
            if (!NativeUpdateFailurePolicy.CheckSafelyAsync(Check, CancellationToken.None).GetAwaiter().GetResult() || calls != 2)
                throw new InvalidOperationException("A failed check prevented the next automatic check.");
        }
        using var lifetime = new CancellationTokenSource();
        try
        {
            NativeUpdateFailurePolicy.CheckSafelyAsync(_ =>
            {
                lifetime.Cancel();
                return Task.FromException<bool>(new OperationCanceledException(lifetime.Token));
            }, lifetime.Token).GetAwaiter().GetResult();
            throw new InvalidOperationException("Lifetime cancellation was swallowed.");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
}

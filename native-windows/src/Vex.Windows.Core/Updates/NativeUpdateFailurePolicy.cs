using System.ComponentModel;
using System.Security;
using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.Core.Updates;

public static class NativeUpdateFailurePolicy
{
    public static bool IsExpectedFailure(Exception error) => error is
        HttpRequestException or IOException or UnauthorizedAccessException or
        SecurityException or CryptographicException or JsonException or
        InvalidOperationException or FormatException or Win32Exception or
        OperationCanceledException;

    public static async Task<bool> CheckSafelyAsync(Func<CancellationToken, Task<bool>> check,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(check);
        cancellationToken.ThrowIfCancellationRequested();
        try { return await check(cancellationToken).ConfigureAwait(false); }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested && IsExpectedFailure(error))
        {
            System.Diagnostics.Debug.WriteLine($"Automatic update check failed: {error.GetType().Name}");
            return false;
        }
    }
}

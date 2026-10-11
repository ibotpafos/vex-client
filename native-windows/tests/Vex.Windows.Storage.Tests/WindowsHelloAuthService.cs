namespace Vex.Windows.App.Auth;

public sealed record WindowsHelloAvailability(bool IsAvailable, string Label);

public sealed record WindowsHelloPromptResult(bool Success, string Message);

// These storage cases never request biometric verification. The shim excludes
// WinRT and fails if the linked store unexpectedly asks to display a prompt.
// DPAPI, serialization and file replacement still use the actual app source.
public sealed class WindowsHelloAuthService
{
    public Task<WindowsHelloAvailability> GetAvailabilityAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new WindowsHelloAvailability(false, "Storage acceptance"));
    }

    public Task<WindowsHelloPromptResult> VerifyAsync(nint windowHandle,
        string message, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        throw new InvalidOperationException("Storage acceptance must not invoke Windows Hello.");
    }
}

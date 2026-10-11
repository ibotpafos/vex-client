using System.Net.Sockets;

namespace Vex.Windows.VpnAcceptance;

internal static class PhysicalNetworkProbe
{
    internal static async Task<bool> IsReachableAsync(Func<CancellationToken, Task> operation,
        TimeSpan budget, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(budget);
        try
        {
            token.ThrowIfCancellationRequested();
            await operation(deadline.Token);
            token.ThrowIfCancellationRequested();
            return true;
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !token.IsCancellationRequested)
        {
            return false;
        }
        catch (SocketException error) when (!token.IsCancellationRequested &&
            error.SocketErrorCode is SocketError.AccessDenied or SocketError.TimedOut)
        {
            return false;
        }
        // Refusal and unreachable errors can be remote RST/ICMP responses to
        // traffic that escaped the physical interface. They are inconclusive,
        // so propagate them instead of qualifying an AntiLeak denial.
    }
}

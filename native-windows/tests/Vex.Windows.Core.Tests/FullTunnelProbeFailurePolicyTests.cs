using System.Net.Sockets;
using Vex.Windows.VpnAcceptance;

internal static class FullTunnelProbeFailurePolicyTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        var budget = TimeSpan.FromSeconds(2);
        Require(await PhysicalNetworkProbe.IsReachableAsync(_ => Task.CompletedTask, budget, default),
            "A successful physical probe was classified as blocked.");
        foreach (var code in new[] { SocketError.AccessDenied, SocketError.TimedOut })
        {
            Require(!await PhysicalNetworkProbe.IsReachableAsync(_ =>
                Task.FromException(new SocketException((int)code)), budget, default),
                "An explicit local denial or bounded timeout lost its blocked result.");
        }
        foreach (var code in new[] { SocketError.ConnectionRefused, SocketError.HostUnreachable,
            SocketError.NetworkUnreachable, SocketError.ConnectionReset })
        {
            var failure = new SocketException((int)code);
            await RequireFailureAsync(failure, () => PhysicalNetworkProbe.IsReachableAsync(_ =>
                Task.FromException(failure), budget, default),
                "A remote/network failure qualified an AntiLeak denial.");
        }
        var unrelatedCancellation = new OperationCanceledException();
        await RequireFailureAsync(unrelatedCancellation, () => PhysicalNetworkProbe.IsReachableAsync(_ =>
            Task.FromException(unrelatedCancellation), budget, default),
            "Unrelated cancellation qualified an exhausted probe deadline.");

        using (var caller = new CancellationTokenSource())
        {
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var pending = PhysicalNetworkProbe.IsReachableAsync(async token =>
            {
                entered.SetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
            }, budget, caller.Token);
            await entered.Task;
            caller.Cancel();
            try { await pending; throw new InvalidOperationException("Caller cancellation qualified blocked traffic."); }
            catch (OperationCanceledException) when (caller.IsCancellationRequested) { }
        }
        Require(!await PhysicalNetworkProbe.IsReachableAsync(token => Task.Delay(Timeout.InfiniteTimeSpan, token),
            TimeSpan.FromMilliseconds(50), default), "An exhausted independent probe deadline lost its blocked result.");
    }

    private static async Task RequireFailureAsync(Exception expected, Func<Task<bool>> operation, string message)
    {
        try { await operation(); }
        catch (Exception actual) when (ReferenceEquals(actual, expected)) { return; }
        throw new InvalidOperationException(message);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

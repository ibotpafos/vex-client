using System.Net;

namespace Vex.Windows.Core.Vpn;

public static class BoundedDnsResolver
{
    public static async Task<IPAddress[]> ResolveAsync(string host,
        Func<string, CancellationToken, Task<IPAddress[]>> resolver,
        TimeSpan budget, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(budget);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            return await resolver(host, deadline.Token).WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("endpoint_resolution_timeout");
        }
    }
}

using System.IO.Pipes;
using System.Text;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

internal static class AmneziaPeerStatusClient
{
    public static async Task<VpnPeerStatistics> ReadAsync(
        string serverPublicKey,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            // Official amneziawg-go Windows UAPI; access is restricted to SYSTEM
            // and Administrators by the vendor's security descriptor.
            await using var pipe = new NamedPipeClientStream(
                ".", @"ProtectedPrefix\Administrators\AmneziaWG\vex",
                PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            await pipe.WriteAsync("get=1\n\n"u8.ToArray(), timeout.Token).ConfigureAwait(false);
            await pipe.FlushAsync(timeout.Token).ConfigureAwait(false);
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
            var lines = new List<string>();
            var length = 0;
            while (true)
            {
                var line = await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false);
                if (line is null) { throw new VpnTunnelException("tunnel_peer_status_invalid"); }
                if (line.Length == 0) { break; }
                length += line.Length;
                // UAPI emits one allowed_ip= line per route, which is larger
                // than the signed JSON list for the supported 2048 routes.
                if (line.Length > 4096 || length > 128 * 1024)
                {
                    throw new VpnTunnelException("tunnel_peer_status_invalid");
                }
                lines.Add(line);
            }
            return VpnPeerStatistics.Parse(lines, serverPublicKey);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("tunnel_peer_status_unavailable");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new VpnTunnelException("tunnel_peer_status_unavailable");
        }
    }
}

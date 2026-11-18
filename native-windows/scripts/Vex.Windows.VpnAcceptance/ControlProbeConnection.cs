using System.Net;
using System.Net.Sockets;

namespace Vex.Windows.VpnAcceptance;

// Observe whether any TCP connect completed before this probe's result snapshot.
// Keep callback state separate from the result dictionary: cancellation can
// complete SendAsync while its connection callback is still unwinding.
internal sealed class ControlProbeConnection
{
    private int _state;

    internal bool? TcpConnected => Volatile.Read(ref _state) switch
    {
        0 => null,
        1 => false,
        _ => true,
    };

    internal async ValueTask<Stream> ConnectAsync(Socket socket, EndPoint destination, CancellationToken token)
    {
        Interlocked.CompareExchange(ref _state, 1, 0);
        try
        {
            await socket.ConnectAsync(destination, token);
            Volatile.Write(ref _state, 2);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch { socket.Dispose(); throw; }
    }
}

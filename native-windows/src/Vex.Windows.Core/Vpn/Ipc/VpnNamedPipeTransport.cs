using System.IO.Pipes;
using System.Security.Principal;

namespace Vex.Windows.Core.Vpn.Ipc;

/// <summary>Framed transport whose caller must attest the connected server before authorization is read.</summary>
public sealed class VpnNamedPipeTransport
{
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(50);

    private readonly string _pipeName;
    private readonly Action<NamedPipeClientStream> _attestServer;
    private readonly Func<string> _readAuthorization;

    public VpnNamedPipeTransport(string pipeName,
        Action<NamedPipeClientStream> attestServer, Func<string> readAuthorization)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        ArgumentNullException.ThrowIfNull(attestServer);
        ArgumentNullException.ThrowIfNull(readAuthorization);
        _pipeName = pipeName;
        _attestServer = attestServer;
        _readAuthorization = readAuthorization;
    }

    public async Task<VpnServiceResponse> SendAsync(VpnServiceRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        using var requestDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        requestDeadline.CancelAfter(RequestTimeout);
        await using var pipe = new NamedPipeClientStream(".", _pipeName,
            PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.WriteThrough,
            TokenImpersonationLevel.Identification);
        using (var connectDeadline = CancellationTokenSource.CreateLinkedTokenSource(requestDeadline.Token))
        {
            connectDeadline.CancelAfter(ConnectTimeout);
            try
            {
                await pipe.ConnectAsync(connectDeadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException error) when (
                !requestDeadline.IsCancellationRequested && connectDeadline.IsCancellationRequested)
            {
                throw new IOException("The VEX VPN service is unavailable.", error);
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        _attestServer(pipe);
        var envelope = new VpnIpcRequestEnvelope(_readAuthorization(), request);
        await VpnIpcFrameCodec.WriteRequestAsync(pipe, envelope, requestDeadline.Token).ConfigureAwait(false);
        var response = await VpnIpcFrameCodec.ReadResponseAsync(pipe, requestDeadline.Token).ConfigureAwait(false);
        if (!string.Equals(request.RequestId, response.RequestId, StringComparison.Ordinal))
            throw new VpnIpcProtocolException("response_request_id_mismatch");
        return response;
    }
}

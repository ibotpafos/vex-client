using System.Diagnostics;
using System.IO.Pipes;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

internal static class VpnNamedPipeTransportTests
{
    private const string Authorization = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    public static IEnumerable<(string Name, Action Test)> Cases =>
    [
        ("Absent VPN service fails within the pipe connection deadline", () => MissingServiceAsync().GetAwaiter().GetResult()),
        ("Pipe transport preserves caller cancellation", () => CallerCancellationAsync().GetAwaiter().GetResult()),
        ("Pipe response waiting preserves caller cancellation", () => ResponseCancellationAsync().GetAwaiter().GetResult()),
        ("Pipe attestation precedes authorization and framing", () => AttestationPrecedesSecretsAsync().GetAwaiter().GetResult()),
        ("Real pipe roundtrip keeps a longer operation deadline", () => RoundtripAsync().GetAwaiter().GetResult()),
        ("Pipe transport rejects a response for another request", () => MismatchedResponseAsync().GetAwaiter().GetResult()),
    ];

    private static string PipeName() => "Vex.Transport.Tests." + Guid.NewGuid().ToString("N");
    private static VpnServiceResponse Response(string requestId) =>
        new(requestId, true, VpnConnectionSnapshot.Disconnected(), null);

    private static async Task MissingServiceAsync()
    {
        var transport = new VpnNamedPipeTransport(PipeName(), _ => throw new Exception("Unexpected server"),
            () => throw new Exception("Authorization must not be read"));
        var timer = Stopwatch.StartNew();
        try { await transport.SendAsync(VpnServiceRequest.Status("absent"), CancellationToken.None); }
        catch (IOException)
        {
            Require(timer.Elapsed < TimeSpan.FromSeconds(8), "Unavailable service retained the operation deadline");
            return;
        }
        throw new Exception("Unavailable service did not fail");
    }

    private static async Task CallerCancellationAsync()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var transport = new VpnNamedPipeTransport(PipeName(), _ => { }, () => Authorization);
        try { await transport.SendAsync(VpnServiceRequest.Status("cancel"), cancellation.Token); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
        throw new Exception("Caller cancellation was converted into service unavailability");
    }

    private static async Task AttestationPrecedesSecretsAsync()
    {
        var name = PipeName();
        await using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var received = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(deadline.Token);
            var buffer = new byte[1];
            try { return await server.ReadAsync(buffer, deadline.Token); }
            catch (IOException error) when (OperatingSystem.IsWindows() &&
                (error.HResult & 0xffff) is 109 /* ERROR_BROKEN_PIPE */ or 232 /* ERROR_NO_DATA */)
            {
                // Windows reports these exact EOF states when an unattested
                // client closes without writing; Unix returns zero bytes.
                return 0;
            }
        });
        var authorizationReads = 0;
        var transport = new VpnNamedPipeTransport(name, _ => throw new UnauthorizedAccessException(),
            () => { authorizationReads++; return Authorization; });
        try { await transport.SendAsync(VpnServiceRequest.Status("attest"), deadline.Token); }
        catch (UnauthorizedAccessException)
        {
            Require(authorizationReads == 0 && await received == 0, "Unattested server received authorization/framing");
            return;
        }
        throw new Exception("Attestation rejection was ignored");
    }

    private static async Task ResponseCancellationAsync()
    {
        var name = PipeName();
        await using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var caller = new CancellationTokenSource();
        var peer = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(deadline.Token);
            _ = await VpnIpcFrameCodec.ReadRequestAsync(server, deadline.Token);
            caller.Cancel();
        });
        var transport = new VpnNamedPipeTransport(name, _ => { }, () => Authorization);
        try { await transport.SendAsync(VpnServiceRequest.Status("response-cancel"), caller.Token); }
        catch (OperationCanceledException) when (caller.IsCancellationRequested)
        {
            await peer;
            return;
        }
        throw new Exception("Response cancellation was ignored or converted to another error");
    }

    private static async Task RoundtripAsync()
    {
        var name = PipeName();
        await using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        var peer = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(deadline.Token);
            var envelope = await VpnIpcFrameCodec.ReadRequestAsync(server, deadline.Token);
            Require(envelope.Authorization == Authorization && envelope.Request.RequestId == "roundtrip", "Frame contents changed");
            await Task.Delay(VpnNamedPipeTransport.ConnectTimeout + TimeSpan.FromMilliseconds(150), deadline.Token);
            await VpnIpcFrameCodec.WriteResponseAsync(server, Response(envelope.Request.RequestId), deadline.Token);
        });
        var attested = false;
        var transport = new VpnNamedPipeTransport(name, pipe => attested = pipe.IsConnected,
            () => { Require(attested, "Authorization read before attestation"); return Authorization; });
        var response = await transport.SendAsync(VpnServiceRequest.Status("roundtrip"), deadline.Token);
        Require(response.Success, "Response failed after the connection-only deadline");
        await peer;
    }

    private static async Task MismatchedResponseAsync()
    {
        var name = PipeName();
        await using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var peer = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(deadline.Token);
            _ = await VpnIpcFrameCodec.ReadRequestAsync(server, deadline.Token);
            await VpnIpcFrameCodec.WriteResponseAsync(server, Response("another-request"), deadline.Token);
        });
        var transport = new VpnNamedPipeTransport(name, _ => { }, () => Authorization);
        try { await transport.SendAsync(VpnServiceRequest.Status("expected"), deadline.Token); }
        catch (VpnIpcProtocolException error) when (error.Code == "response_request_id_mismatch")
        {
            await peer;
            return;
        }
        throw new Exception("Mismatched response was accepted");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
}

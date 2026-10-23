using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Vex.Windows.VpnAcceptance;

internal static class ControlProbeConnectionTests
{
    public static readonly (string Name, Action Run)[] Cases =
    [
        ("Control probe keeps failed socket connects distinct from TLS", () => FailedConnectAsync().GetAwaiter().GetResult()),
        ("Control probe preserves caller cancellation and socket cleanup", () => CancelledConnectAsync().GetAwaiter().GetResult()),
        ("Control probe transfers connected socket ownership to its stream", () => ConnectedStreamOwnershipAsync().GetAwaiter().GetResult()),
        ("Control probe observes TCP completion before a TLS connect timeout", () => TlsHandshakeTimeoutAsync().GetAwaiter().GetResult()),
        ("Control probe never accepts an untrusted TLS certificate", () => UntrustedTlsAsync().GetAwaiter().GetResult()),
    ];

    private static Socket Socket() => new(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);

    private static async Task FailedConnectAsync()
    {
        using var client = Socket();
        var handle = client.SafeHandle;
        var connection = new ControlProbeConnection();
        Require(connection.TcpConnected is null, "An unattempted connect invented a TCP result.");
        client.Dispose();
        try
        {
            using var stream = await connection.ConnectAsync(client, new IPEndPoint(IPAddress.Loopback, 443), default);
            throw new InvalidOperationException("A closed socket returned a connected stream.");
        }
        catch (ObjectDisposedException) { }
        Require(connection.TcpConnected == false && handle.IsClosed,
            "A failed TCP connect lost its observation or socket cleanup.");
    }

    private static async Task CancelledConnectAsync()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var client = Socket();
        var handle = client.SafeHandle;
        var connection = new ControlProbeConnection();
        using var caller = new CancellationTokenSource();
        caller.Cancel();
        try
        {
            using var stream = await connection.ConnectAsync(client, listener.LocalEndpoint, caller.Token);
            throw new InvalidOperationException("A cancelled connect returned a stream.");
        }
        catch (OperationCanceledException error) when (error.CancellationToken == caller.Token) { }
        Require(connection.TcpConnected == false && handle.IsClosed,
            "Caller cancellation lost its TCP observation or socket cleanup.");
    }

    private static async Task ConnectedStreamOwnershipAsync()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var client = Socket();
        var handle = client.SafeHandle;
        var connection = new ControlProbeConnection();
        var accepting = listener.AcceptSocketAsync(deadline.Token);
        await using (var stream = await connection.ConnectAsync(client, listener.LocalEndpoint, deadline.Token))
        {
            using var peer = await accepting;
            await stream.WriteAsync(new byte[] { 42 }, deadline.Token);
            var received = new byte[1];
            Require(await peer.ReceiveAsync(received, SocketFlags.None, deadline.Token) == 1 && received[0] == 42 &&
                connection.TcpConnected == true && !handle.IsClosed,
                "A connected stream lost its TCP observation or bytes.");
        }
        Require(handle.IsClosed, "The returned stream did not own its socket.");
    }

    private static SocketsHttpHandler Handler(ControlProbeConnection connection, EndPoint destination) => new()
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(1),
        ConnectCallback = (_, token) => connection.ConnectAsync(Socket(), destination, token),
    };

    private static async Task TlsHandshakeTimeoutAsync()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var connection = new ControlProbeConnection();
        using var handler = Handler(connection, listener.LocalEndpoint);
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var accepting = listener.AcceptSocketAsync(deadline.Token);
        var pending = client.GetAsync("https://control.example.test/", HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        using var peer = await accepting;
        var hello = new byte[1];
        Require(await peer.ReceiveAsync(hello, SocketFlags.None, deadline.Token) == 1 && hello[0] == 0x16,
            "The loopback peer did not receive a TLS ClientHello.");
        // Hold the already-connected peer open without a TLS response. The
        // handler's connect timer must expire while the caller is still live.
        try
        {
            using var response = await pending;
            throw new InvalidOperationException("A stalled TLS peer returned an HTTP response.");
        }
        catch (OperationCanceledException error)
        {
            var facts = new Dictionary<string, object?>();
            AcceptanceFailure.RecordControlProbeCancellation(facts, error, default, deadline.Token);
            Require(connection.TcpConnected == true &&
                Equals(facts["full_control_probe_parent_cancelled"], false) &&
                Equals(facts["full_control_probe_budget_expired"], false) &&
                Equals(facts["full_control_probe_inner_timeout"], true),
                "TLS connect timeout was confused with an uncompleted TCP connect or caller cancellation.");
        }
    }

    private static async Task UntrustedTlsAsync()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=control.example.test", key, HashAlgorithmName.SHA256);
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName("control.example.test");
        request.CertificateExtensions.Add(names.Build());
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(5));
        var connection = new ControlProbeConnection();
        using var handler = Handler(connection, listener.LocalEndpoint);
        // Give the certificate validation case its own ample fixture bound;
        // production connect/operation limits remain in FullTunnelAcceptance.
        handler.ConnectTimeout = TimeSpan.FromSeconds(5);
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var accepting = listener.AcceptSocketAsync(deadline.Token);
        var pending = client.GetAsync("https://control.example.test/", HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        using var peer = await accepting;
        using var tls = new SslStream(new NetworkStream(peer, ownsSocket: false));
        var handshake = tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
        {
            ServerCertificate = certificate,
        }, deadline.Token);
        try
        {
            using var response = await pending;
            throw new InvalidOperationException("An untrusted TLS certificate qualified a control-plane probe.");
        }
        catch (HttpRequestException error) when (error.HttpRequestError == HttpRequestError.SecureConnectionError)
        {
            Require(connection.TcpConnected == true, "TLS rejection lost its completed TCP observation.");
        }
        finally
        {
            deadline.Cancel();
            try { await handshake; }
            catch (Exception error) when (error is AuthenticationException or IOException or OperationCanceledException) { }
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

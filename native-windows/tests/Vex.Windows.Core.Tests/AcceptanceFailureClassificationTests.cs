using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using Vex.Windows.VpnAcceptance;

internal static class AcceptanceFailureClassificationTests
{
    public static void Run()
    {
        foreach (var (failure, expected) in new (Exception, string)[]
        {
            (new HttpRequestException(HttpRequestError.NameResolutionError, "QSECRET"), "dns"),
            (new HttpRequestException(HttpRequestError.SecureConnectionError, "QSECRET"), "tls"),
            (new HttpRequestException(HttpRequestError.ConnectionError, "QSECRET"), "connection"),
            (new HttpRequestException(HttpRequestError.HttpProtocolError, "QSECRET"), "protocol"),
            (new HttpRequestException(HttpRequestError.InvalidResponse, "QSECRET"), "protocol"),
            (new HttpRequestException(HttpRequestError.ResponseEnded, "QSECRET"), "protocol"),
            (new HttpRequestException("QSECRET", new AuthenticationException("QSECRET")), "tls"),
            (new HttpRequestException("QSECRET", new OperationCanceledException("QSECRET")), "cancelled"),
            (new InvalidOperationException("QSECRET", new HttpRequestException(HttpRequestError.NameResolutionError, "QSECRET")), "dns"),
            (new SocketException((int)SocketError.HostNotFound), "dns"),
            (new SocketException((int)SocketError.TimedOut), "timeout"),
            (new SocketException((int)SocketError.ConnectionRefused), "connection"),
            (new SocketException((int)SocketError.AccessDenied), "socket"),
            (new HttpRequestException("QSECRET"), "http"),
            (new InvalidOperationException("QSECRET"), "other"),
        })
        {
            var actual = AcceptanceFailure.Classify(failure);
            if (actual != expected || actual.Contains("QSECRET", StringComparison.Ordinal))
                throw new InvalidOperationException("Acceptance failure lost its fixed privacy-safe category.");
        }
        Exception nested = new AuthenticationException("QSECRET");
        for (var i = 0; i < 9; i++) nested = new Exception("QSECRET", nested);
        if (AcceptanceFailure.Classify(nested) != "other")
            throw new InvalidOperationException("Acceptance failure exceeded its bounded inner-chain inspection.");
    }
}

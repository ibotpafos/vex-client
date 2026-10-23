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
        foreach (var (parentCancelled, budgetExpired, innerTimeout) in new[]
            { (false, false, false), (true, false, false), (true, true, false), (false, true, false), (false, false, true) })
        {
            using var parent = new CancellationTokenSource();
            using var deadline = new CancellationTokenSource();
            if (parentCancelled) parent.Cancel();
            if (budgetExpired) deadline.Cancel();
            var error = new OperationCanceledException("QSECRET", innerTimeout ? new TimeoutException("QSECRET") : null);
            var result = new Dictionary<string, object?>();
            AcceptanceFailure.RecordControlProbeCancellation(result, error, parent.Token, deadline.Token);
            if (!Equals(result["full_control_probe_parent_cancelled"], parentCancelled) ||
                !Equals(result["full_control_probe_budget_expired"], budgetExpired) ||
                !Equals(result["full_control_probe_inner_timeout"], innerTimeout) ||
                System.Text.Json.JsonSerializer.Serialize(result).Contains("QSECRET", StringComparison.Ordinal))
                throw new InvalidOperationException("Control probe cancellation facts changed or leaked private data.");
        }
        Exception nested = new AuthenticationException("QSECRET");
        for (var i = 0; i < 9; i++) nested = new Exception("QSECRET", nested);
        if (AcceptanceFailure.Classify(nested) != "other")
            throw new InvalidOperationException("Acceptance failure exceeded its bounded inner-chain inspection.");
    }
}

using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;

namespace Vex.Windows.VpnAcceptance;

// Bounded, fixed categories only. Exception messages/types/addresses never
// enter public CI logs, and classification does not change the verdict.
internal static class AcceptanceFailure
{
    internal static void RecordControlProbeCancellation(IDictionary<string, object?> result,
        OperationCanceledException error, CancellationToken parent, CancellationToken budget)
    {
        result["full_control_probe_parent_cancelled"] = parent.IsCancellationRequested;
        result["full_control_probe_budget_expired"] = budget.IsCancellationRequested;
        result["full_control_probe_inner_timeout"] = error.InnerException is TimeoutException;
    }

    internal static string Classify(Exception error)
    {
        var fallback = "other";
        for (var depth = 0; error is not null && depth < 8; depth++, error = error.InnerException!)
        {
            if (error is AuthenticationException) return "tls";
            if (error is OperationCanceledException) return "cancelled";
            if (error is SocketException socket)
                return socket.SocketErrorCode switch
                {
                    SocketError.HostNotFound or SocketError.NoData => "dns",
                    SocketError.TimedOut => "timeout",
                    SocketError.ConnectionRefused or SocketError.ConnectionReset or
                        SocketError.HostUnreachable or SocketError.NetworkUnreachable => "connection",
                    _ => "socket",
                };
            if (error is HttpRequestException http)
            {
                var category = http.HttpRequestError switch
                {
                    HttpRequestError.NameResolutionError => "dns",
                    HttpRequestError.SecureConnectionError => "tls",
                    HttpRequestError.ConnectionError => "connection",
                    HttpRequestError.HttpProtocolError or HttpRequestError.InvalidResponse or
                        HttpRequestError.ResponseEnded => "protocol",
                    _ => null,
                };
                if (category is not null) return category;
                fallback = "http";
            }
        }
        return fallback;
    }
}

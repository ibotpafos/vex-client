using System.Net;
using System.Text;
using Vex.Windows.App.Auth;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;

internal static class VexApiErrorContractTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        foreach (var (body, expected) in new[]
        {
            ("{\"code\":\"unauthorized\",\"message\":\"mfa required\",\"details\":{}}", "mfa_required"),
            ("{\"code\":\"unauthorized\",\"message\":\"invalid mfa code\"}", "mfa_invalid"),
            ("{\"code\":\"mfa_required\",\"message\":\"Known MFA code\"}", "mfa_required"),
            ("{\"code\":\"unauthorized\",\"message\":\"internal token secret / mfa required\"}", "session_expired"),
            ("{\"code\":\"untrusted_mfa_required\",\"message\":\"mfa required\"}", "session_expired"),
            ("{\"code\":\"unauthorized\",\"message\":\"mfa required\",\"message\":\"different\"}", "session_expired"),
            ("{\"code\":\"unauthorized\",\"message\":null}", "session_expired"),
            ("not JSON", "session_expired"),
            ("{\"code\":\"unauthorized\",\"message\":\"mfa required\",\"padding\":\"" + new string('x', 5000) + "\"}", "session_expired"),
        })
        {
            var client = Client(_ => Response(HttpStatusCode.Unauthorized, body));
            await ExpectCodeAsync(() => client.ConfirmEmailOtpAsync("user@example.com", "challenge-1", "123456",
                CancellationToken.None), expected, HttpStatusCode.Unauthorized);
        }
        var wrongEndpoint = Client(_ => Response(HttpStatusCode.Unauthorized,
            "{\"code\":\"unauthorized\",\"message\":\"mfa required\"}"));
        await ExpectCodeAsync(() => wrongEndpoint.GetCurrentUserAsync("access-token", CancellationToken.None),
            "session_expired", HttpStatusCode.Unauthorized);

        var quota = Client(_ => Response(HttpStatusCode.Forbidden,
            "{\"code\":\"forbidden\",\"message\":\"device limit reached\",\"details\":{}}"));
        await ExpectCodeAsync(() => quota.RegisterNativeDeviceAsync("access-token", "installation-1",
            WireGuardIdentity.Generate().PublicKey, 1, "fi-1", "1.0.0", CancellationToken.None),
            "vpn_device_limit_reached", HttpStatusCode.Forbidden);
        var wrongStatus = Client(_ => Response(HttpStatusCode.InternalServerError,
            "{\"code\":\"mfa_required\",\"message\":\"mfa required\"}"));
        await ExpectCodeAsync(() => wrongStatus.ConfirmEmailOtpAsync("user@example.com", "challenge-1", "123456",
            CancellationToken.None), "api_request_failed", HttpStatusCode.InternalServerError);

        var api = Client(request => request.RequestUri!.AbsolutePath == "/v1/auth/email-otp/request"
            ? Response(HttpStatusCode.OK, "{\"challenge_id\":\"challenge-1\",\"expires_at\":\"2099-01-01T00:00:00Z\"}")
            : Response(HttpStatusCode.Unauthorized, "{\"code\":\"unauthorized\",\"message\":\"mfa required\",\"details\":{}}"));
        var store = new MemoryClientStateStore();
        var auth = new NativeAuthService(api, new(api, store, new FakeVpnControlClient(), "1.0.0"),
            store, new PkceStore(), new("https://api.example.test"), _ => Task.FromResult(true));
        await auth.RequestEmailOtpAsync("user@example.com", CancellationToken.None);
        await auth.ConfirmEmailOtpAsync("user@example.com", "123456", CancellationToken.None);
        Check(auth.Error?.Contains("двухфакторной", StringComparison.Ordinal) == true &&
            auth.Error.Contains("сайт", StringComparison.Ordinal) && store.State is null,
            "Actual HTTP OTP MFA must suggest browser verification without saving a partial session.");
    }

    private static VexApiClient Client(Func<HttpRequestMessage, HttpResponseMessage> respond) =>
        new(new HttpClient(new RoutingHttpHandler(respond)) { BaseAddress = new("https://api.example.test") });

    private static HttpResponseMessage Response(HttpStatusCode status, string body) => new(status)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    private static async Task ExpectCodeAsync(Func<Task> action, string code, HttpStatusCode status)
    {
        try
        {
            await action().WaitAsync(TimeSpan.FromSeconds(5));
            throw new InvalidOperationException("Expected a classified VEX API error.");
        }
        catch (VexApiException error)
        {
            Check(error.Code == code && error.StatusCode == status,
                "Known error classification changed or exposed arbitrary backend text.");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class PkceStore : IPkceStateStore
    {
        public PendingPkceChallenge? Load() => null;
        public void Save(PendingPkceChallenge challenge) { }
        public void Clear() { }
    }
}

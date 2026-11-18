using Vex.Windows.App.Auth;
using Vex.Windows.Client.Session;
using System.Net;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;

internal static class VexApiConfigurationTests
{
    public static IEnumerable<(string Name, Action Run)> All =>
    [
        ("Windows API configuration rejects invalid bases before I/O", RejectInvalidApiBases),
        ("Windows PKCE rejects invalid bases before generating challenges", RejectInvalidPkceBases),
        ("Windows HTTP, PKCE and realtime preserve configured path prefixes", () => PreservePrefixesAsync().GetAwaiter().GetResult()),
    ];

    private static Uri[] InvalidBases =>
    [
        new("https://inert-user:inert-fixture@api.example.test"),
        new("https://api.example.test?tenant=x"),
        new("https://api.example.test#fragment"),
        new("ftp://127.0.0.1"),
        new("http://api.example.test"),
    ];

    private static void RejectInvalidApiBases()
    {
        using var validHttp = new HttpClient(new Handler(_ => throw new InvalidOperationException("Unexpected auth I/O.")))
            { BaseAddress = new("https://api.example.test") };
        var validApi = new VexApiClient(validHttp);
        foreach (var uri in InvalidBases.Cast<Uri?>().Append(null))
        {
            var sends = 0;
            using var http = new HttpClient(new Handler(_ =>
            {
                sends++;
                return new(HttpStatusCode.OK);
            })) { BaseAddress = uri };
            Check(Rejected(() => _ = new VexApiClient(http)) && sends == 0,
                "Invalid API configuration was accepted or reached the HTTP handler.");
            Check(Rejected(() =>
            {
                var realtime = new CustomerRealtimeClient(http);
                realtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }) && sends == 0, "Invalid realtime configuration was accepted or reached I/O.");
            var state = new MemoryClientStateStore();
            var coordinator = new NativeClientCoordinator(validApi, state, new FakeVpnControlClient(), "1.0.0");
            Check(Rejected(() => _ = new NativeAuthService(validApi, coordinator, state, new UnreachablePkceStore(),
                uri!, _ => throw new InvalidOperationException("Unexpected browser launch."))) && state.State is null,
                "Invalid auth configuration was accepted or touched the stored session.");
        }
        foreach (var value in new[] { "https://api.example.test", "http://127.0.0.1:3001", "http://localhost:3001", "http://[::1]:3001" })
        {
            using var http = new HttpClient(new Handler(_ => throw new InvalidOperationException("Unexpected I/O.")))
                { BaseAddress = new(value) };
            _ = new VexApiClient(http);
        }
        foreach (var empty in new string?[] { null, "", "  " })
            Check(VexApiConfiguration.Resolve(empty).AbsoluteUri == "https://vexguard.app/",
                "Missing configuration changed the production default.");
        foreach (var invalid in new[] { "/relative", "not-a-url", "https://api.example.test:65536", "https://api.example.test?tenant=x" })
            Check(Rejected(() => _ = VexApiConfiguration.Resolve(invalid)), "Invalid configuration silently selected a fallback.");
    }

    private static void RejectInvalidPkceBases()
    {
        foreach (var uri in InvalidBases.Append(new Uri("/relative", UriKind.Relative)))
        {
            var nonces = 0;
            var rejected = Rejected(() => _ = PkceAuthFlow.CreateRequest(uri, "inert-installation", "Windows", "windows",
                WebAuthMode.Login, randomString: length => { nonces++; return new string('a', length); }));
            Check(rejected && nonces == 0, $"Invalid PKCE configuration created {nonces} nonces or was accepted.");
        }
    }

    private static async Task PreservePrefixesAsync()
    {
        foreach (var prefix in new[] { "/tenant/vpn/", "/tenant%20space/vpn/" })
        {
            var baseUri = new Uri("https://api.example.test" + prefix);
            var paths = new List<string>();
            using var http = new HttpClient(new Handler(request =>
            {
                paths.Add(request.RequestUri!.AbsolutePath);
                if (request.RequestUri.AbsolutePath.EndsWith("/auth/login", StringComparison.Ordinal))
                    return new(HttpStatusCode.Unauthorized) { Content = new StringContent("{\"code\":\"mfa_required\"}") };
                if (request.RequestUri.AbsolutePath.EndsWith("/auth/me", StringComparison.Ordinal))
                {
                    Check(request.Headers.Authorization?.Parameter == "inert-fixture-token", "Authorization changed during endpoint resolution.");
                    return new(HttpStatusCode.OK) { Content = new StringContent("{\"id\":\"fixture-user\",\"email\":\"user@example.com\"}") };
                }
                return new(HttpStatusCode.OK) { Content = new StringContent("[]") };
            })) { BaseAddress = baseUri };
            var api = new VexApiClient(http);
            await api.GetBillingPlansAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
            Check(paths[^1] == prefix + "v1/billing/plans", "An API request lost its configured path prefix.");
            var user = await api.GetCurrentUserAsync("inert-fixture-token", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
            Check(user.Id == "fixture-user" && paths[^1] == prefix + "v1/auth/me", "An authorized endpoint lost its path prefix.");
            try
            {
                await api.LoginAsync("user@example.com", "inert-fixture-password", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
                throw new InvalidOperationException("Expected the known MFA error.");
            }
            catch (VexApiException error)
            {
                Check(error.Code == "mfa_required" && paths[^1] == prefix + "v1/auth/login",
                    "A prefixed auth endpoint lost its safe error classification.");
            }
            var pkce = PkceAuthFlow.CreateRequest(baseUri, "inert-installation", "Windows", "windows",
                WebAuthMode.Login, randomString: length => new string('b', length));
            Check(pkce.Url.AbsolutePath == prefix + "auth/app" && pkce.Url.Authority == baseUri.Authority,
                "PKCE lost its configured origin or prefix.");
            var seen = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var streamHttp = new HttpClient(new Handler(request =>
            {
                seen.TrySetResult(request.RequestUri!);
                return new(HttpStatusCode.Unauthorized);
            })) { BaseAddress = baseUri };
            await using var realtime = new CustomerRealtimeClient(streamHttp);
            await realtime.StartAsync("inert-fixture-token");
            var streamUri = await seen.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await realtime.StopAsync();
            Check(streamUri.AbsolutePath == prefix + "v1/events" && streamUri.Authority == baseUri.Authority,
                "Realtime lost its configured origin or prefix.");
        }
    }

    private static bool Rejected(Action action)
    {
        try { action(); return false; }
        catch (ArgumentException error)
        {
            Check(error.Message.StartsWith("invalid_api_base_url", StringComparison.Ordinal), "Configuration lost its fixed local error code.");
            return true;
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class UnreachablePkceStore : IPkceStateStore
    {
        public PendingPkceChallenge? Load() => throw new InvalidOperationException("Invalid configuration read PKCE state.");
        public void Save(PendingPkceChallenge challenge) => throw new InvalidOperationException("Invalid configuration wrote PKCE state.");
        public void Clear() => throw new InvalidOperationException("Invalid configuration cleared PKCE state.");
    }

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => Task.FromResult(respond(request));
    }
}

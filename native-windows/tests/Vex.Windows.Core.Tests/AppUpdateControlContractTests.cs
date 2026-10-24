using System.Net;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;

internal static class AppUpdateControlContractTests
{
    private static readonly ClientAppMetadata Metadata = new("windows", "1.2.3", 123, "stable", "1.0",
        "Windows 11", "x64", "fixture-api", 1);

    public static void Run()
    {
        var cases = new List<(string Name, object? Payload)>
        {
            ("empty object", new { }), ("missing availability", new { required = false }),
            ("missing requirement", new { updateAvailable = false }),
            ("canonical null precedes legacy", new { updateAvailable = (bool?)null, update_available = true, required = false }),
        };
        object?[] wrong = [null, 0, 1, "false", "true", Array.Empty<object>(), new { }];
        foreach (var field in new[] { "updateAvailable", "required" })
        foreach (var value in wrong)
        {
            var payload = new Dictionary<string, object?> { ["updateAvailable"] = false, ["required"] = false, [field] = value };
            cases.Add((field + "=" + JsonSerializer.Serialize(value), payload));
        }
        foreach (var value in wrong.Where(value => value is not null))
            cases.Add(("blocked=" + JsonSerializer.Serialize(value), new { updateAvailable = false, required = false, currentBuildBlocked = value }));
        foreach (var value in new object?[] { null, Array.Empty<object>(), new[] { false }, true, "false", 0 })
            cases.Add(("root=" + JsonSerializer.Serialize(value), value));
        var admitted = new List<string>();
        foreach (var (name, payload) in cases)
        {
            using var handler = new Handler(JsonSerializer.Serialize(payload));
            using var http = new HttpClient(handler) { BaseAddress = new Uri("https://api.example.test") };
            try
            {
                new VexApiClient(http).CheckForAppUpdateAsync(Metadata, default).GetAwaiter().GetResult();
                admitted.Add(name);
            }
            catch (VexApiException error) when (error.Code == "api_response_invalid" && error.StatusCode == HttpStatusCode.BadGateway) { }
            if (handler.Calls != 1) throw new InvalidOperationException("Invalid metadata replayed its POST.");
        }
        if (admitted.Count != 0) throw new InvalidOperationException("Malformed update decisions admitted: " + string.Join(", ", admitted));

        foreach (var payload in new[]
        {
            """{"updateAvailable":false,"required":false}""",
            """{"updateAvailable":false,"required":true,"currentBuildBlocked":true}""",
            """{"updateAvailable":true,"required":false,"currentBuildBlocked":false}""",
            """{"updateAvailable":true,"required":true,"currentBuildBlocked":true}""",
            """{"updateAvailable":false,"required":false,"currentBuildBlocked":null}""",
            """{"update_available":true,"required":true,"latest_version":"1.3.0"}""",
            """{"updateAvailable":false,"update_available":true,"required":false}""",
        })
        {
            using var handler = new Handler(payload);
            using var http = new HttpClient(handler) { BaseAddress = new Uri("https://api.example.test") };
            var update = new VexApiClient(http).CheckForAppUpdateAsync(Metadata, default).GetAwaiter().GetResult();
            using var wire = JsonDocument.Parse(payload);
            var root = wire.RootElement;
            var available = root.TryGetProperty("updateAvailable", out var canonical) ? canonical.GetBoolean() : root.GetProperty("update_available").GetBoolean();
            if (update.UpdateAvailable != available || update.Required != root.GetProperty("required").GetBoolean())
                throw new InvalidOperationException("Valid update controls or canonical precedence changed.");
        }
    }

    private sealed class Handler(string payload) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Calls++;
            if (request.Method != HttpMethod.Post || request.RequestUri!.AbsolutePath != "/v1/app/update/check")
                throw new InvalidOperationException("Unexpected metadata request.");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(payload, Encoding.UTF8, "application/json"),
            });
        }
    }
}

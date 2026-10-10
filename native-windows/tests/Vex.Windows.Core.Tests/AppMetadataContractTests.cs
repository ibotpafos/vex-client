using System.Net;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;

internal static class AppMetadataContractTests
{
    public static void Run()
    {
        var metadata = new ClientAppMetadata("windows", "1.2.3", 123, "stable", "1.0",
            "Windows 11", "arm64", "native-windows-1", 1);
        using var handler = new Handler("""
            {"version":"config-9","releasedAt":"2026-10-10T00:00:00Z","platform":"windows","channel":"stable",
             "minSupportedBuild":100,"recommendedBuild":130,"recommendedVersion":"1.3.0","coreVersion":"3.1",
             "configSchemaVersion":2,"minConfigSchemaVersion":1,"routingPolicyVersion":"2026.10",
             "featureFlags":{"dynamic_routes":true},"incidentBanner":"Плановые работы"}
            """);
        var client = new VexApiClient(new HttpClient(handler) { BaseAddress = new Uri("https://api.example.test") });
        var config = client.GetRemoteConfigAsync(metadata, CancellationToken.None).GetAwaiter().GetResult();
        Equal("Плановые работы", config.IncidentBanner);
        Equal(100, config.MinSupportedBuild);
        Equal(130, config.RecommendedBuild);
        Equal(2, config.ConfigSchemaVersion);
        Equal("2026.10", config.RoutingPolicyVersion);
        Equal(true, config.FeatureFlags!["dynamic_routes"]);
        using (var request = JsonDocument.Parse(handler.Body!))
        {
            Equal(123, request.RootElement.GetProperty("buildNumber").GetInt32());
            Equal("arm64", request.RootElement.GetProperty("arch").GetString());
        }
        var legacy = JsonSerializer.Deserialize<AppRemoteConfig>("""
            {"incident_banner":"legacy","routing_policy_version":"legacy-route","feature_flags":{"a":true}}
            """)!;
        Equal("legacy", legacy.IncidentBanner);
        Equal("legacy-route", legacy.RoutingPolicyVersion);
        var canonical = JsonSerializer.Deserialize<AppRemoteConfig>("""
            {"incidentBanner":"current","incident_banner":"old","routingPolicyVersion":"current-route","routing_policy_version":"old-route"}
            """)!;
        Equal("current", canonical.IncidentBanner);
        Equal("current-route", canonical.RoutingPolicyVersion);
        Equal(null, JsonSerializer.Deserialize<AppRemoteConfig>("""{"IncidentBanner":"wrong-case"}""")!.IncidentBanner);

        handler.Payload = """
            {"updateAvailable":true,"required":true,"delivery":"native_windows","currentBuildBlocked":true,
             "latestVersion":"1.3.0","latestBuild":130,"minSupportedBuild":125,"minConfigSchemaVersion":2,
             "downloadUrl":"https://downloads.example.test/vex.msix","checksumSha256":"hash",
             "signatureUrl":"https://downloads.example.test/vex.sig","rolloutPercent":100,"checkedAt":"2026-10-10T00:00:00Z"}
            """;
        var update = client.CheckForAppUpdateAsync(metadata, CancellationToken.None).GetAwaiter().GetResult();
        Equal(true, update.UpdateAvailable);
        Equal(true, update.Required);
        Equal(true, update.CurrentBuildBlocked);
        Equal("1.3.0", update.LatestVersion);
        Equal(130, update.LatestBuild);
        Equal(125, update.MinSupportedBuild);
        Equal(2, update.MinConfigSchemaVersion);
        Equal("native_windows", update.Delivery);
        var legacyUpdate = JsonSerializer.Deserialize<AppUpdateCheckResult>("""
            {"update_available":true,"required":true,"latest_version":"1.4.0","latest_build":140,"current_build_blocked":true}
            """)!;
        Equal(true, legacyUpdate.UpdateAvailable);
        Equal("1.4.0", legacyUpdate.LatestVersion);
        Equal(true, legacyUpdate.CurrentBuildBlocked);
        handler.Payload = """{"featureFlags":{"dynamic_routes":"invalid"}}""";
        try
        {
            client.GetRemoteConfigAsync(metadata, CancellationToken.None).GetAwaiter().GetResult();
            throw new InvalidOperationException("Malformed remote config was admitted.");
        }
        catch (VexApiException error) when (error.Code == "api_response_invalid") { }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
    }

    private sealed class Handler(string payload) : HttpMessageHandler
    {
        public string Payload { get; set; } = payload;
        public string? Body { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Body = request.Content is null ? null : await request.Content.ReadAsStringAsync(token);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Payload, Encoding.UTF8, "application/json"),
            };
        }
    }
}

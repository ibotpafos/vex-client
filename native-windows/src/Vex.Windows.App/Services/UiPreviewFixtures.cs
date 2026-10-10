using System.Net;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

// Fixtures are compiled only into Debug UI-review builds. They use neither a
// production token nor a signed VPN profile, and never contact the service.
internal static class UiPreviewFixtures
{
#if DEBUG
    private static int _connectRequests;
    private static int _trustedConnectRequests;

    internal static void RecordTrayRecovery(string scenario, AppServices services)
    {
        if (!UiPreviewContext.IsEnabled || UiPreviewContext.StateDirectory is null)
            throw new InvalidOperationException("Tray diagnostics require isolated UI preview.");
        var path = Path.Combine(Path.GetTempPath(), $"vex-ui-preview-tray-{Environment.ProcessId}.json");
        var value = JsonSerializer.Serialize(new
        {
            schema = "vex.windows.ui-preview-tray-recovery.v1",
            process_id = Environment.ProcessId,
            preview_mode = UiPreviewContext.IsAuthenticated ? "fixtures" : "signed-out",
            scenario,
            access = services.Coordinator.CurrentStateAccess.ToString(),
            connect_requests = Volatile.Read(ref _connectRequests),
            trusted_connect_requests = Volatile.Read(ref _trustedConnectRequests),
            connection_desired = services.VpnUiState.ConnectionDesired,
            waiting_for_browser_auth = services.Auth.IsWaitingForBrowserAuth,
            handler_completed = true,
        });
        File.WriteAllText(path + ".tmp", value);
        File.Move(path + ".tmp", path, overwrite: true);
    }
#endif

    public static VpnServiceResponse ServiceResponse(VpnServiceRequest request)
    {
        if (!UiPreviewContext.IsEnabled)
            throw new InvalidOperationException("UI preview is not enabled.");
#if DEBUG
        if (request.Operation == VpnServiceOperation.Connect)
        {
            Interlocked.Increment(ref _connectRequests);
            if (request.ProfileAuthorization is not null) Interlocked.Increment(ref _trustedConnectRequests);
        }
#endif
        return new VpnServiceResponse(request.RequestId, true,
            VpnConnectionSnapshot.Disconnected() with { Diagnostics = VpnTunnelDiagnostics.Empty }, null);
    }

    public static void Seed(ProtectedClientStateStore store)
    {
#if DEBUG
        if (!UiPreviewContext.IsAuthenticated) return;
        var now = DateTimeOffset.UtcNow;
        var key = Convert.ToBase64String(Enumerable.Range(1, 32).Select(value => (byte)value).ToArray());
        store.Save(new NativeClientState(
            new VexAuthSession(new VexUser("ui-preview-user", "preview@example.test", "active"),
                "isolated-ui-preview-token", now.AddDays(1)),
            "ui-preview-installation", "ui-preview-device", "de-frankfurt",
            new WireGuardIdentity(key, key, 1)));
#endif
    }

    public static HttpMessageHandler CreateHandler() => new OfflineHandler();

    private sealed class OfflineHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!UiPreviewContext.IsEnabled)
                throw new InvalidOperationException("UI preview is not enabled.");
#if DEBUG
            var path = request.RequestUri?.AbsolutePath ?? "";
            // Navigation GETs and read-only app-metadata POSTs use the same
            // decoding path as production. Mutations are deliberately refused.
            object? data = request.Method == HttpMethod.Get || path == "/v1/app/remote-config"
                ? ResponseFor(path) : null;
            var status = data is null ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK;
            data ??= new { code = "ui_preview_read_only" };
            var response = new HttpResponseMessage(status)
            {
                Content = new StringContent(JsonSerializer.Serialize(data), Encoding.UTF8, "application/json"),
                RequestMessage = request,
            };
            // Exercise real page-loading cancellation and responsiveness with
            // an isolated slow read; no production network is involved.
            return path == "/v1/app/remote-config"
                ? DelayedSettingsResponseAsync(response, cancellationToken)
                : Task.FromResult(response);
#else
            throw new InvalidOperationException("UI fixtures are unavailable in Release builds.");
#endif
        }

#if DEBUG
        private static async Task<HttpResponseMessage> DelayedSettingsResponseAsync(
            HttpResponseMessage response, CancellationToken cancellationToken)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
                return response;
            }
            catch
            {
                response.Dispose();
                throw;
            }
        }

        private static object? ResponseFor(string path)
        {
            var now = DateTimeOffset.UtcNow;
            var nextMonth = now.AddDays(30).ToString("O");
            return path switch
            {
                "/v1/me" or "/v1/auth/me" => new VexUser("ui-preview-user", "preview@example.test", "active"),
                "/v1/billing/entitlement" => new VexEntitlement(true, "vex-monthly", "VEX", "active",
                    "Подписка VEX", "Все устройства под защитой", "Осталось 30 дней", "active",
                    "premium", nextMonth, nextMonth, true),
                "/v1/billing/plans" => new[] { new BillingPlan("vex-monthly", "VEX", "platega", 29900,
                    "RUB", "month", 5, "premium", "active") },
                "/v1/billing/payments" => new[] { new BillingPayment("ui-preview-payment", null, null,
                    "vex-monthly", "platega", 29900, "RUB", "card", "paid", null, null, null, null,
                    now.AddDays(-1).ToString("O"), now.AddDays(-1).ToString("O")) },
                "/v1/devices" => new[] { new VpnDevice("ui-preview-device", "Этот компьютер", "active",
                    null, "10.77.0.2", "de-frankfurt", "amneziawg", "AmneziaWG 3.1",
                    "192.0.2.1:443", 28, Platform: "windows") },
                "/v1/devices/usage" => new { usage = new[] { new VpnDeviceUsage("ui-preview-device",
                    "disconnected", false, null, 0, 0, 0) } },
                "/v1/vpn/locations" => new[] {
                    new VpnLocation("de-frankfurt", "Frankfurt", "available", 3, "DE", "🇩🇪", "online", 28, 3),
                    new VpnLocation("fi-helsinki", "Helsinki", "available", 2, "FI", "🇫🇮", "online", 42, 2),
                    new VpnLocation("nl-amsterdam", "Amsterdam", "available", 2, "NL", "🇳🇱", "online", 36, 2) },
                "/v1/app/remote-config" => new { version = "ui-preview", platform = "windows",
                    channel = "stable", configSchemaVersion = 3, minConfigSchemaVersion = 1,
                    featureFlags = new Dictionary<string, bool>(), incidentBanner = (string?)null },
                _ => null,
            };
        }
#endif
    }
}

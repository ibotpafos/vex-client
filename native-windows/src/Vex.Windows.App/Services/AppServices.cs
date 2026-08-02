using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using System.Net;
using System.Security.Cryptography.X509Certificates;
using Vex.Windows.App.Auth;

namespace Vex.Windows.App.Services;

public sealed class AppServices
{
    private static readonly Lazy<AppServices> SharedServices =
        new(() => new AppServices());

    private AppServices()
    {
#if DEBUG
        var apiBaseUrl =
            Environment.GetEnvironmentVariable("VEX_API_BASE_URL") ??
            "https://vexguard.app";
#else
        const string apiBaseUrl = "https://vexguard.app";
#endif
        AppVersion =
            typeof(App).Assembly.GetName().Version?.ToString() ??
            "0.0.0";
        var httpHandler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression =
                DecompressionMethods.Brotli |
                DecompressionMethods.GZip |
                DecompressionMethods.Deflate,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        httpHandler.SslOptions.CertificateRevocationCheckMode =
            X509RevocationMode.Online;
        var httpClient = new HttpClient(httpHandler)
        {
            BaseAddress = new Uri(apiBaseUrl, UriKind.Absolute),
            // Profile issuance performs server-side node selection and may
            // legitimately take longer than ordinary control-plane calls.
            // macOS hides this behind profile warmup; Windows must still let
            // the first cold request complete so subsequent connects use the
            // signed local cache.
            Timeout = TimeSpan.FromSeconds(40),
        };
        StateStore = new ProtectedClientStateStore();
        var apiClient = new VexApiClient(httpClient, StateStore);
        VpnClient = new VpnServiceClient(
            new ProtectedAuthorizationStore());
        Coordinator = new NativeClientCoordinator(
            apiClient,
            StateStore,
            VpnClient,
            AppVersion);
        Auth = new NativeAuthService(
            apiClient,
            Coordinator,
            StateStore,
            new ProtectedPkceStateStore(),
            apiClient.BaseUri);
        UpdateService = new NativeUpdateService(
            StateStore.GetOrCreateInstallationId());
        Preferences = new NativeClientPreferencesStore();
        BackgroundUpdates = new NativeUpdateBackgroundHost(
            UpdateService,
            Preferences);
        StartupService = new WindowsStartupService();
        VpnUiState = new VpnUiStateService(VpnClient);
        ProductParity = new VpnProductParityService();
        ServiceMaintenance = new WindowsServiceMaintenanceService();
        SupportSocketClient.Current.ConfigureEndpointProvider(
            (_, cancellationToken) =>
                Coordinator.GetSupportWebSocketUriAsync(
                    cancellationToken));
        DiagnosticsQueueService.Current.ConfigureUploader(
            UploadQueuedDiagnosticsAsync);
    }

    public static AppServices Current => SharedServices.Value;

    public string AppVersion { get; }

    public VpnServiceClient VpnClient { get; }

    public NativeClientCoordinator Coordinator { get; }

    public ProtectedClientStateStore StateStore { get; }

    public NativeAuthService Auth { get; }

    public NativeUpdateService UpdateService { get; }

    public NativeClientPreferencesStore Preferences { get; }

    public NativeUpdateBackgroundHost BackgroundUpdates { get; }

    public WindowsStartupService StartupService { get; }

    public VpnUiStateService VpnUiState { get; }

    public VpnProductParityService ProductParity { get; }

    public WindowsServiceMaintenanceService ServiceMaintenance { get; }

    public MainWindow? MainWindow { get; private set; }

    public void RegisterMainWindow(MainWindow window)
    {
        ArgumentNullException.ThrowIfNull(window);
        MainWindow = window;
    }

    public void ClearMainWindow(MainWindow window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (ReferenceEquals(MainWindow, window))
        {
            MainWindow = null;
        }
    }

    private Task UploadQueuedDiagnosticsAsync(
        QueuedDiagnosticsReport queued,
        CancellationToken cancellationToken)
    {
        var snapshot = VpnUiState.Snapshot;
        var report = new ClientDiagnosticsReport(
            DeviceId: Coordinator.CurrentState?.DeviceId,
            Platform: "windows",
            AppVersion: AppVersion,
            Reason: queued.Reason,
            Status: queued.Status,
            VpnState: snapshot.Phase.ToString().ToLowerInvariant(),
            Endpoint: Sample(queued, "endpoint"),
            DnsOk: BooleanSample(queued, "dns_ok"),
            HttpsOk: BooleanSample(queued, "https_ok"),
            LatencyAverageMs: DoubleSample(
                queued,
                "latency_avg_ms"),
            RxBytes: checked((long)Math.Min(
                VpnUiState.ReceivedBytes,
                (ulong)long.MaxValue)),
            TxBytes: checked((long)Math.Min(
                VpnUiState.SentBytes,
                (ulong)long.MaxValue)),
            Samples: queued.Samples);
        return Coordinator.SubmitClientDiagnosticsAsync(
            report,
            cancellationToken);
    }

    private static string? Sample(
        QueuedDiagnosticsReport report,
        string key) =>
        report.Samples.TryGetValue(key, out var value) &&
        !string.IsNullOrWhiteSpace(value)
            ? value
            : null;

    private static bool BooleanSample(
        QueuedDiagnosticsReport report,
        string key) =>
        bool.TryParse(Sample(report, key), out var value) &&
        value;

    private static double? DoubleSample(
        QueuedDiagnosticsReport report,
        string key) =>
        double.TryParse(
            Sample(report, key),
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            out var value)
            ? value
            : null;
}

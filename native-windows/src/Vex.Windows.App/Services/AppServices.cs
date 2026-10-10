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
        var httpClient = new HttpClient(UiPreviewContext.IsEnabled
            ? UiPreviewFixtures.CreateHandler() : httpHandler)
        {
            BaseAddress = new Uri(apiBaseUrl, UriKind.Absolute),
            // Profile issuance performs server-side node selection and may
            // legitimately take longer than ordinary control-plane calls.
            // Background warm-up usually fills the signed local cache. A cold
            // foreground request must still have enough time to complete.
            Timeout = TimeSpan.FromSeconds(40),
        };
        StateStore = new ProtectedClientStateStore(stateDirectory: UiPreviewContext.StateDirectory);
        UiPreviewFixtures.Seed(StateStore);
        var apiClient = new VexApiClient(httpClient, StateStore);
        var realtimeHttpHandler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        realtimeHttpHandler.SslOptions.CertificateRevocationCheckMode =
            X509RevocationMode.Online;
        Realtime = new CustomerRealtimeClient(new HttpClient(UiPreviewContext.IsEnabled
            ? UiPreviewFixtures.CreateHandler() : realtimeHttpHandler)
        {
            BaseAddress = apiClient.BaseUri,
            Timeout = Timeout.InfiniteTimeSpan,
        });
        VpnClient = new VpnServiceClient(
            new ProtectedAuthorizationStore());
        Coordinator = new NativeClientCoordinator(
            apiClient,
            StateStore,
            VpnClient,
            AppVersion,
            dynamicRoutes: new DynamicRouteEngine(new ProtectedDynamicRouteStore(UiPreviewContext.StateDirectory)),
            profileWarmupVerifier: () => UiPreviewContext.IsEnabled ? null : ProfileWarmupTrustStore.Load());
        Auth = new NativeAuthService(
            apiClient,
            Coordinator,
            StateStore,
            new ProtectedPkceStateStore(UiPreviewContext.StateDirectory),
            apiClient.BaseUri,
            async uri => !UiPreviewContext.IsEnabled &&
                await global::Windows.System.Launcher.LaunchUriAsync(uri));
        Auth.StateChanged += OnAuthStateChanged;
        Realtime.Changed += OnRealtimeChanged;
        UpdateService = new NativeUpdateService(
            GetUpdateInstallationId());
        Preferences = new NativeClientPreferencesStore(UiPreviewContext.StateDirectory is { } previewDirectory
            ? Path.Combine(previewDirectory, "preferences.v1.dpapi") : null);
#if DEBUG
        if (UiPreviewContext.StateDirectory is { } diagnosticsDirectory)
            DiagnosticsQueueService.UseIsolatedPreview(diagnosticsDirectory);
#endif
        BackgroundUpdates = new NativeUpdateBackgroundHost(
            UpdateService,
            Preferences);
        StartupService = new WindowsStartupService();
        VpnUiState = new VpnUiStateService(VpnClient.GetDiagnosticsAsync);
        ProductParity = new VpnProductParityService();
        BackgroundVpn = new NativeVpnBackgroundHost(this);
        ProfileWarmup = new NativeProfileWarmupHost(this);
        ServiceMaintenance = new WindowsServiceMaintenanceService(VpnClient.GetDiagnosticsAsync);
        DiagnosticsQueueService.Current.ConfigureUploader(
            UploadQueuedDiagnosticsAsync);
        Coordinator.SessionChanged += OnCoordinatorSessionChanged;
        _ = SynchronizeRealtimeAsync();
    }

    public static AppServices Current => SharedServices.Value;

    private string GetUpdateInstallationId()
    {
        try
        {
            return StateStore.GetOrCreateInstallationId();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException or System.Text.Json.JsonException)
        {
            // Keep update recovery available without replacing the identity
            // used for device provisioning. This fallback stays local.
            var seed = System.Text.Encoding.UTF8.GetBytes(
                Environment.MachineName + "\\" + Environment.UserName);
            return "update-only-" + Convert.ToHexString(
                System.Security.Cryptography.SHA256.HashData(seed));
        }
    }

    public string AppVersion { get; }

    public VpnServiceClient VpnClient { get; }

    public NativeClientCoordinator Coordinator { get; }

    public ProtectedClientStateStore StateStore { get; }

    public NativeAuthService Auth { get; }

    public CustomerRealtimeClient Realtime { get; }

    public event EventHandler<CustomerRealtimeChangedEventArgs>?
        CustomerRealtimeChanged;

    public NativeUpdateService UpdateService { get; }

    public NativeClientPreferencesStore Preferences { get; }

    public NativeUpdateBackgroundHost BackgroundUpdates { get; }

    public WindowsStartupService StartupService { get; }

    public VpnUiStateService VpnUiState { get; }

    public VpnProductParityService ProductParity { get; }

    public NativeVpnBackgroundHost BackgroundVpn { get; }

    public NativeProfileWarmupHost ProfileWarmup { get; }

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

    private void OnAuthStateChanged(object? sender, EventArgs args) =>
        _ = SynchronizeRealtimeAsync();

    private void OnCoordinatorSessionChanged(object? sender, EventArgs args)
    {
        if (Coordinator.CurrentStateAccess == ClientStateAccessKind.Missing)
        {
            VpnUiState.MarkConnectionDesired(false);
            Auth.ReportSessionExpired();
        }
        else
        {
            if (args is AuthenticatedSessionAcceptedEventArgs)
                VpnUiState.MarkConnectionDesired(false);
            Auth.ClearStatus();
        }
        BackgroundVpn.Wake();
    }

    private CustomerRealtimeSessionRecovery? _realtimeSessionRecovery;
    private readonly SemaphoreSlim _realtimeSynchronization = new(1, 1);

    private CustomerRealtimeSessionRecovery RealtimeSessionRecovery =>
        LazyInitializer.EnsureInitialized(ref _realtimeSessionRecovery, () =>
            new CustomerRealtimeSessionRecovery(Coordinator, (_, _) => SynchronizeRealtimeAsync(), Realtime.StopAsync,
                SignOutRejectedSessionAsync));

    private async Task SignOutRejectedSessionAsync(string expectedAccessToken, CancellationToken cancellationToken)
    {
        var matched = false;
        try
        {
            await VpnUiState.RunAsync(async token =>
            {
                await Coordinator.SignOutAsync(token, expectedAccessToken, () =>
                {
                    matched = true;
                    VpnUiState.MarkConnectionDesired(false);
                });
                return await VpnClient.GetDiagnosticsAsync(token);
            }, cancellationToken);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            InvalidOperationException or OperationCanceledException or
            System.Security.Cryptography.CryptographicException or Vex.Windows.Core.Vpn.Ipc.VpnIpcProtocolException)
        {
            // Disconnect failures retain explicit cleanup intent for the watchdog.
        }
        finally
        {
            if (matched && Coordinator.CurrentStateAccess == ClientStateAccessKind.Missing)
                Auth.ReportSessionExpired();
            BackgroundVpn.Wake();
        }
    }

    private void OnRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args) =>
        _ = HandleRealtimeEventAsync(args);

    private async Task HandleRealtimeEventAsync(
        CustomerRealtimeChangedEventArgs args)
    {
        if (args.Event.Type is "customer.session.revoked" or "customer.session.refresh_required")
        {
            await RealtimeSessionRecovery.HandleAsync(args);
            return;
        }

        if (args.Event.Type == "customer.resync" ||
            args.Metadata.Domains.Any(domain => domain is "entitlement" or "billing" or "devices" or "provisioning"))
        {
            try
            {
                var state = Coordinator.CurrentState;
                if (state is null || args.SourceTokenFingerprint !=
                    CustomerRealtimeClient.TokenFingerprint(state.Session.AccessToken)) return;
                var expectedAccessToken = state.Session.AccessToken;
                await Coordinator.InvalidateCachedEntitlementAsync(CancellationToken.None, expectedAccessToken);
                if (args.Event.Type == "customer.resync" ||
                    args.Metadata.Domains.Any(domain => domain is "devices" or "provisioning"))
                    await Coordinator.InvalidateProfileAsync(CancellationToken.None, expectedAccessToken);
                if (args.Event.Type == "customer.resync" ||
                    args.Metadata.Domains.Any(domain => domain is "entitlement" or "billing"))
                    await Coordinator.ValidateEntitlementAsync(CancellationToken.None, expectedAccessToken);
            }
            catch (NativeClientFlowException error) when (
                Vex.Windows.Core.Vpn.VpnRecoveryPolicy.IsTerminalError(error.Code))
            {
                try
                {
                    await VpnUiState.RunAsync(async token =>
                    {
                        var state = Coordinator.CurrentState;
                        if (state is null || args.SourceTokenFingerprint !=
                            CustomerRealtimeClient.TokenFingerprint(state.Session.AccessToken))
                            return new Vex.Windows.Core.Vpn.VpnServiceResponse(
                                Guid.NewGuid().ToString("N"), true, VpnUiState.Snapshot, null);
                        VpnUiState.MarkConnectionDesired(false);
                        return await VpnClient.DisconnectAsync(token);
                    }, CancellationToken.None);
                }
                catch (Exception cleanupError) when (cleanupError is IOException or
                    UnauthorizedAccessException or InvalidOperationException or
                    System.Security.Cryptography.CryptographicException or OperationCanceledException or
                    Vex.Windows.Core.Vpn.Ipc.VpnIpcProtocolException)
                {
                    // Shared state retains the service failure and cleanup evidence.
                }
            }
            catch (Exception error) when (error is NativeClientFlowException or IOException or
                UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or
                HttpRequestException or VexApiException or OperationCanceledException)
            {
                // The session may have been cleared or locked during the event.
            }
        }
        BackgroundVpn.Wake();
        CustomerRealtimeChanged?.Invoke(this, args);
    }

    private async Task SynchronizeRealtimeAsync()
    {
        if (UiPreviewContext.IsEnabled) return;
        await _realtimeSynchronization.WaitAsync();
        try
        {
            // Read after entering the gate: an older auth notification must
            // not restart a cleared or replaced session's stream.
            NativeClientState? state;
            try
            {
                state = Coordinator.CurrentState;
            }
            catch (Exception error) when (
                error is IOException or
                    UnauthorizedAccessException or
                    System.Security.Cryptography.CryptographicException)
            {
                state = null;
            }

            if (state is null)
            {
                await Realtime.StopAsync();
                return;
            }
            await Realtime.StartAsync(
                state.Session.AccessToken,
                CancellationToken.None);
        }
        finally { _realtimeSynchronization.Release(); }
    }

    private Task UploadQueuedDiagnosticsAsync(
        QueuedDiagnosticsReport queued,
        CancellationToken cancellationToken)
    {
        var snapshot = VpnUiState.Snapshot;
        var deviceId = Coordinator.CurrentState?.DeviceId;
        var report = new ClientDiagnosticsReport(
            DeviceId: string.IsNullOrWhiteSpace(deviceId) ? null : deviceId,
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

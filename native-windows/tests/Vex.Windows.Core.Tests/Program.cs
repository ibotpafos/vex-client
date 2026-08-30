using Vex.Windows.Core.Navigation;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;
using Vex.Windows.Core.Updates;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Client.Updates;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

var tests = new (string Name, Action Run)[]
{
    ("Navigation matches native macOS sections", NavigationMatchesMac),
    ("Windows location labels are localized for presentation", WindowsLocationLabelsAreLocalized),
    ("Automatic location reuses the healthy cached server", AutomaticLocationReusesHealthyCachedServer),
    ("Automatic location falls back to the lowest latency", AutomaticLocationUsesLowestLatencyFallback),
    ("Disconnected can begin connecting", DisconnectedCanBeginConnecting),
    ("Connected ignores a duplicate connect", ConnectedIgnoresDuplicateConnect),
    ("Disconnect wins over an in-flight connect", DisconnectWinsOverConnect),
    ("Late connect completion cannot undo disconnect", LateConnectCannotUndoDisconnect),
    ("Service error preserves a safe disconnected state", ErrorIsSafe),
    ("Degraded active tunnel chooses cleanup instead of reconnect", DegradedTunnelChoosesCleanup),
    ("Offline error without an adapter remains reconnectable", OfflineErrorRemainsReconnectable),
    ("Client failure preserves degraded cleanup evidence", ClientFailurePreservesCleanupEvidence),
    ("Connection action policy covers every phase", ConnectionActionPolicyCoversEveryPhase),
    ("Stale service snapshots are ignored", StaleSnapshotsAreIgnored),
    ("IPC requests enforce the current protocol", IpcRequestsEnforceProtocol),
    ("IPC logging never exposes the tunnel config", IpcLoggingRedactsTunnelConfig),
    ("IPC requests reject an empty request id", IpcRejectsEmptyRequestId),
    ("IPC connect requires location and tunnel config", IpcConnectRequiresPayload),
    ("IPC status rejects tunnel payload", IpcStatusRejectsPayload),
    ("IPC failure responses require an error code", IpcFailureRequiresError),
    ("Active service snapshots require a location", ActiveSnapshotRequiresLocation),
    ("Service handler connects through the tunnel runtime", ServiceHandlerConnects),
    ("Service handler is idempotent by request id", ServiceHandlerIsIdempotent),
    ("Service handler sanitizes unexpected runtime failures", ServiceHandlerSanitizesFailures),
    ("VPN error codes preserve safe profile verification failures", VpnErrorCodesPreserveSafeProfileFailures),
    ("VPN error codes reject unsafe diagnostic text", VpnErrorCodesRejectUnsafeText),
    ("Service handler propagates cancellation", ServiceHandlerPropagatesCancellation),
    ("Service handler rejects request id payload conflicts", ServiceHandlerRejectsIdConflict),
    ("IPC frame roundtrips an authenticated request", IpcFrameRoundTrips),
    ("IPC frame rejects truncated input", IpcFrameRejectsTruncation),
    ("IPC frame rejects oversized input", IpcFrameRejectsOversize),
    ("IPC authentication uses exact token matching", IpcAuthenticationIsExact),
    ("IPC envelope logging redacts credentials and config", IpcEnvelopeLoggingRedactsSecrets),
    ("Tunnel config accepts the managed profile grammar", TunnelConfigAcceptsManagedProfile),
    ("Tunnel config rejects script directives", TunnelConfigRejectsScripts),
    ("Tunnel config rejects unknown fields", TunnelConfigRejectsUnknownFields),
    ("IPC access policy blocks unsigned connect profiles", IpcPolicyBlocksUnsignedConnect),
    ("Signed profile materializes a trusted tunnel", SignedProfileMaterializesTunnel),
    ("Signed profile rejects payload tampering", SignedProfileRejectsTampering),
    ("Signed profile rejects expiration", SignedProfileRejectsExpiration),
    ("Signed profile reports an unsupported tunnel protocol", SignedProfileReportsUnsupportedProtocol),
    ("Signed profile identifies an unknown signed payload field", SignedProfileIdentifiesUnknownPayloadField),
    ("Signed profile identifies an invalid local key", SignedProfileIdentifiesInvalidLocalKey),
    ("Signed profile identifies an invalid server key", SignedProfileIdentifiesInvalidServerKey),
    ("Signed profile accepts the Windows route budget", SignedProfileAcceptsWindowsRouteBudget),
    ("Signed profile accepts the backend 24 hour lifetime", SignedProfileAcceptsBackendLifetime),
    ("Signing keyring rejects invalid P-256 keys", SignedProfileRejectsInvalidSigningKey),
    ("Signed profile logging redacts key material", SignedProfileLoggingRedactsSecrets),
    ("Windows login uses the native device-session contract", WindowsLoginUsesDeviceSessionContract),
    ("Windows email OTP request uses the backend challenge contract", WindowsEmailOtpRequestUsesContract),
    ("Windows email OTP confirm uses the native device-session contract", WindowsEmailOtpConfirmUsesContract),
    ("Windows email OTP confirm rejects invalid code", WindowsEmailOtpConfirmRejectsInvalidCode),
    ("Windows auth code exchange uses the PKCE token contract", WindowsAuthCodeExchangeUsesPkceContract),
    ("Windows PKCE callback rejects duplicate query items", WindowsPkceCallbackRejectsDuplicateQueryItems),
    ("Windows PKCE callback rejects path-prefix lookalikes", WindowsPkceCallbackRejectsPathPrefixLookalikes),
    ("Windows launch activation accepts the vexguard callback URI", WindowsLaunchActivationAcceptsVexguardUri),
    ("Windows launch activation accepts a quoted vex callback URI", WindowsLaunchActivationAcceptsQuotedVexUri),
    ("Windows launch activation rejects unrelated schemes", WindowsLaunchActivationRejectsUnrelatedSchemes),
    ("Windows launch activation rejects ambiguous arguments", WindowsLaunchActivationRejectsAmbiguousArguments),
    ("Windows profile request preserves signed authorization", WindowsProfilePreservesAuthorization),
    ("Windows profile request sends the cached profile version", WindowsProfileSendsKnownVersion),
    ("Windows registration signs a verified device identity when available", WindowsRegistrationUsesVerifiedDeviceIdentity),
    ("Windows registration fails closed when the identity challenge fails", WindowsRegistrationFailsClosedWithoutIdentityChallenge),
    ("Windows billing summary uses plans and entitlement contracts", WindowsBillingSummaryUsesContracts),
    ("Windows billing checkout uses the native billing contract", WindowsBillingCheckoutUsesContract),
    ("Windows support history preserves the ticket thread contract", WindowsSupportHistoryUsesContract),
    ("Windows control plane exposes macOS parity read APIs", WindowsControlPlaneExposesParityReads),
    ("Windows control plane sends VPN telemetry and diagnostics", WindowsControlPlaneSendsTelemetryAndDiagnostics),
    ("Windows control plane exposes support socket and app configuration", WindowsControlPlaneExposesSupportAndAppConfiguration),
    ("Windows realtime parser preserves complete SSE frames", WindowsRealtimeParserPreservesFrames),
    ("Windows realtime metadata rejects unknown domains", WindowsRealtimeMetadataRejectsUnknownDomains),
    ("Windows realtime refresh policy ignores heartbeats", WindowsRealtimeRefreshPolicyIgnoresHeartbeats),
    ("Windows realtime reconnect delay is bounded", WindowsRealtimeReconnectDelayIsBounded),
    ("Windows realtime transport authenticates and emits change events", WindowsRealtimeTransportAuthenticatesAndEmits),
    ("Windows profile request preserves routing mode and bypass region", WindowsProfilePreservesRoutingPreferences),
    ("WireGuard identity generation returns distinct Curve25519 keys", WireGuardIdentityGeneratesKeys),
    ("Windows updater accepts a signed manifest for the active architecture", WindowsUpdaterAcceptsSignedManifest),
    ("Windows updater honors the deterministic staged rollout bucket", WindowsUpdaterHonorsStagedRollout),
    ("Windows updater rejects a tampered manifest", WindowsUpdaterRejectsTamperedManifest),
    ("Windows updater stages atomically and reuses a verified package", WindowsUpdaterStagesAndReusesPackage),
    ("Windows updater re-downloads a cached package when hash is stale", WindowsUpdaterRedownloadsCachedPackageWhenHashMismatched),
    ("Windows updater rejects a package with an unexpected content length", WindowsUpdaterRejectsUnexpectedPackageSize),
    ("Windows updater rejects an oversized manifest response", WindowsUpdaterRejectsOversizedManifest),
    ("Windows updater rejects an executable disguised as an MSIX release", WindowsUpdaterRejectsExecutablePackageUri),
    ("Windows updater rejects a stale signed manifest", WindowsUpdaterRejectsStaleSignedManifest),
    ("Windows updater rejects an older signed manifest after accepting a newer revision", WindowsUpdaterRejectsManifestRevisionReplay),
    ("Windows updater rejects a decreasing required version floor", WindowsUpdaterRejectsRequiredVersionFloorDecrease),
    ("Automatic updater checks on startup and every six hours", AutomaticUpdaterUsesMacParityCadence),
    ("Automatic updater backs off after transient failures", AutomaticUpdaterBacksOffAfterFailure),
    ("Native client provisions once and connects with signed authority", NativeClientProvisionsAndConnects),
    ("Native client provisions a pre-authenticated session", NativeClientProvisionsPreAuthenticatedSession),
    ("Native client reuses signed authority for an unchanged profile", NativeClientReusesUnchangedProfile),
    ("Native client reconnects from cached authority without control-plane calls", NativeClientReconnectsFromCacheWithoutControlPlane),
    ("Native client scopes cached authority to its location and routing policy", NativeClientScopesCachedAuthorityToTarget),
    ("Native client preserves the working profile when a replacement fetch fails", NativeClientPreservesWorkingProfileOnTargetFailure),
    ("Native client reuses cached authority when profile refresh times out", NativeClientReusesCachedProfileAfterTimeout),
    ("Native client refetches when cached profile metadata is corrupted", NativeClientRecoversFromCorruptedProfileCache),
    ("Native client refreshes expiring session at refresh boundary", NativeClientRefreshesExpiringSessionAtBoundary),
    ("Native client rotates an expired device key before connect", NativeClientRotatesExpiredKey),
    ("Native client preserves manual location and routing preferences", NativeClientPreservesManualVpnPreferences),
    ("Native client gates VPN connect on entitlement", NativeClientGatesConnectOnEntitlement),
    ("Native client reports successful connect and disconnect", NativeClientReportsVpnLifecycle),
    ("Native client replies through the active support thread", NativeClientRepliesThroughActiveSupportThread),
    ("Native client derives a support subject for a new thread", NativeClientDerivesSupportSubjectForNewThread),
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception error)
    {
        failures.Add($"{test.Name}: {error.Message}");
        Console.Error.WriteLine($"FAIL {test.Name}: {error.Message}");
    }
}

if (failures.Count > 0)
{
    Environment.ExitCode = 1;
    return;
}

Console.WriteLine($"PASS {tests.Length} tests");

static void NavigationMatchesMac()
{
    var sections = AppSectionCatalog.All;
    Equal(4, sections.Count);
    Equal(AppSection.Home, sections[0].Id);
    Equal("Главная", sections[0].Title);
    Equal(AppSection.Account, sections[1].Id);
    Equal("Аккаунт", sections[1].Title);
    Equal(AppSection.Support, sections[2].Id);
    Equal("Поддержка", sections[2].Title);
    Equal(AppSection.Settings, sections[3].Id);
    Equal("Настройки", sections[3].Title);
}

static void WindowsRealtimeParserPreservesFrames()
{
    var parser = new CustomerSseParser();
    var events = parser.Append(
        "event: customer.change\nid: devices:7\n" +
        "data: {\"domain\":\"devices\",\"version\":7}\n\npart");

    Equal(1, events.Count);
    Equal("customer.change", events[0].Type);
    Equal("devices:7", events[0].Id);
    Equal("{\"domain\":\"devices\",\"version\":7}", events[0].Data);
    Equal("part", parser.Remainder);
}

static void WindowsRealtimeMetadataRejectsUnknownDomains()
{
    Equal<CustomerRealtimeMetadata?>(
        null,
        CustomerRealtimeMetadata.Parse(
            "customer.change",
            "{\"domain\":\"email\",\"version\":1}"));
    var metadata = CustomerRealtimeMetadata.Parse(
        "customer.resync",
        "{\"versions\":[{\"domain\":\"billing\",\"version\":2}],\"reason\":\"initial\"}");
    Equal("initial", metadata?.Reason);
    Equal("billing", metadata?.Domains.Single());
}

static void WindowsRealtimeReconnectDelayIsBounded()
{
    Equal(TimeSpan.FromSeconds(1), CustomerRealtimeClient.ReconnectDelay(0));
    Equal(TimeSpan.FromSeconds(30), CustomerRealtimeClient.ReconnectDelay(20));
}

static void WindowsRealtimeRefreshPolicyIgnoresHeartbeats()
{
    var heartbeat = new CustomerRealtimeChangedEventArgs(
        new CustomerRealtimeEvent("customer.heartbeat", string.Empty, "{}"),
        new CustomerRealtimeMetadata([], string.Empty));
    Equal(false, CustomerRealtimeRefreshPolicy.ShouldRefreshSettings(heartbeat));
    Equal(false, CustomerRealtimeRefreshPolicy.ShouldRefreshAccount(heartbeat));

    var billing = new CustomerRealtimeChangedEventArgs(
        new CustomerRealtimeEvent("customer.change", "billing:2", "{}"),
        new CustomerRealtimeMetadata(["billing"], string.Empty));
    Equal(false, CustomerRealtimeRefreshPolicy.ShouldRefreshSettings(billing));
    Equal(true, CustomerRealtimeRefreshPolicy.ShouldRefreshAccount(billing));

    var releases = new CustomerRealtimeChangedEventArgs(
        new CustomerRealtimeEvent("customer.change", "releases:3", "{}"),
        new CustomerRealtimeMetadata(["releases"], string.Empty));
    Equal(true, CustomerRealtimeRefreshPolicy.ShouldRefreshSettings(releases));
}

static void WindowsRealtimeTransportAuthenticatesAndEmits() =>
    WindowsRealtimeTransportAuthenticatesAndEmitsAsync()
        .GetAwaiter()
        .GetResult();

static async Task WindowsRealtimeTransportAuthenticatesAndEmitsAsync()
{
    var handler = new RealtimeHttpHandler();
    using var httpClient = new HttpClient(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
        Timeout = Timeout.InfiniteTimeSpan,
    };
    await using var client = new CustomerRealtimeClient(httpClient);
    var received = new TaskCompletionSource<CustomerRealtimeChangedEventArgs>(
        TaskCreationOptions.RunContinuationsAsynchronously);
    client.Changed += (_, args) => received.TrySetResult(args);

    await client.StartAsync("fixture-token", CancellationToken.None);
    var changed = await received.Task.WaitAsync(TimeSpan.FromSeconds(2));
    await client.StopAsync();

    Equal("Bearer", handler.AuthorizationScheme);
    Equal("fixture-token", handler.AuthorizationParameter);
    Equal("text/event-stream", handler.AcceptMediaType);
    Equal("/v1/events", handler.RequestPath);
    Equal("customer.change", changed.Event.Type);
    Equal("devices", changed.Metadata.Domains.Single());
}

static void AutomaticLocationReusesHealthyCachedServer()
{
    var locations = new[]
    {
        new VpnLocation("de", "Germany", "available", 1, LatencyMs: 25),
        new VpnLocation("fi", "Finland", "available", 1, LatencyMs: 8),
    };

    Equal(
        "de",
        VpnLocationSelector.SelectAutomaticLocation(
            locations,
            preferredLocationId: "de"));
}

static void AutomaticLocationUsesLowestLatencyFallback()
{
    var locations = new[]
    {
        new VpnLocation("de", "Germany", "available", 2, LatencyMs: 25),
        new VpnLocation("fi", "Finland", "available", 1, LatencyMs: 8),
        new VpnLocation("nl", "Netherlands", "unavailable", 4, LatencyMs: 2),
    };

    Equal(
        "fi",
        VpnLocationSelector.SelectAutomaticLocation(
            locations,
            preferredLocationId: "missing"));
}

static void AutomaticUpdaterUsesMacParityCadence()
{
    var now = new DateTimeOffset(
        2026,
        7,
        30,
        12,
        0,
        0,
        TimeSpan.Zero);

    Equal(true, NativeUpdateCheckPolicy.ShouldCheck(
        automaticChecksEnabled: true,
        lastCheckAt: null,
        now));
    Equal(false, NativeUpdateCheckPolicy.ShouldCheck(
        automaticChecksEnabled: false,
        lastCheckAt: null,
        now));
    Equal(false, NativeUpdateCheckPolicy.ShouldCheck(
        automaticChecksEnabled: true,
        lastCheckAt: now - TimeSpan.FromHours(5),
        now));
    Equal(true, NativeUpdateCheckPolicy.ShouldCheck(
        automaticChecksEnabled: true,
        lastCheckAt: now - TimeSpan.FromHours(6),
        now));
    Equal(
        TimeSpan.FromHours(6),
        NativeUpdateCheckPolicy.NextDelay(lastCheckSucceeded: true));
}

static void WindowsLocationLabelsAreLocalized()
{
    Equal("Финляндия", NativeLocationLabel.Russian("fi"));
    Equal("Финляндия", NativeLocationLabel.Russian("fi-1"));
    Equal("Германия", NativeLocationLabel.Russian("de-2"));
    Equal("Автоматический сервер", NativeLocationLabel.Russian(null));
    Equal("Сервер zz-9", NativeLocationLabel.Russian("zz-9"));
}

static void AutomaticUpdaterBacksOffAfterFailure()
{
    Equal(
        TimeSpan.FromMinutes(15),
        NativeUpdateCheckPolicy.NextDelay(lastCheckSucceeded: false));
}

static void DisconnectedCanBeginConnecting()
{
    var initial = VpnConnectionSnapshot.Disconnected(sequence: 10);
    var next = VpnConnectionReducer.Reduce(initial, new VpnIntent.Connect("fi-1"));

    Equal(VpnConnectionPhase.Connecting, next.Phase);
    Equal("fi-1", next.LocationId);
    Equal(11L, next.Sequence);
}

static void ConnectedIgnoresDuplicateConnect()
{
    var initial = new VpnConnectionSnapshot(
        VpnConnectionPhase.Connected,
        "fi-1",
        Sequence: 20,
        ErrorCode: null);

    var next = VpnConnectionReducer.Reduce(initial, new VpnIntent.Connect("fi-1"));

    Equal(initial, next);
}

static void DisconnectWinsOverConnect()
{
    var initial = new VpnConnectionSnapshot(
        VpnConnectionPhase.Connecting,
        "fi-1",
        Sequence: 30,
        ErrorCode: null);

    var next = VpnConnectionReducer.Reduce(initial, new VpnIntent.Disconnect());

    Equal(VpnConnectionPhase.Disconnecting, next.Phase);
    Equal(31L, next.Sequence);
}

static void LateConnectCannotUndoDisconnect()
{
    var disconnecting = new VpnConnectionSnapshot(
        VpnConnectionPhase.Disconnecting,
        "fi-1",
        Sequence: 31,
        ErrorCode: null);

    var next = VpnConnectionReducer.Reduce(
        disconnecting,
        new VpnIntent.ServiceSnapshot(
            VpnConnectionPhase.Connected,
            "fi-1",
            Sequence: 32,
            ErrorCode: null));

    Equal(disconnecting, next);
}

static void ErrorIsSafe()
{
    var initial = new VpnConnectionSnapshot(
        VpnConnectionPhase.Connecting,
        "fi-1",
        Sequence: 40,
        ErrorCode: null);

    var next = VpnConnectionReducer.Reduce(
        initial,
        new VpnIntent.ServiceSnapshot(
            VpnConnectionPhase.Error,
            "fi-1",
            Sequence: 41,
            ErrorCode: "handshake_timeout"));

    Equal(VpnConnectionPhase.Error, next.Phase);
    Equal("handshake_timeout", next.ErrorCode);

    var retry = VpnConnectionReducer.Reduce(next, new VpnIntent.Connect("fi-1"));
    Equal(VpnConnectionPhase.Connecting, retry.Phase);
    Equal(null, retry.ErrorCode);
}

static void DegradedTunnelChoosesCleanup()
{
    var snapshot = new VpnConnectionSnapshot(
        VpnConnectionPhase.Error,
        "fi-1",
        Sequence: 41,
        ErrorCode: "tunnel_network_degraded")
    {
        Diagnostics = VpnTunnelDiagnostics.Empty with
        {
            AdapterName = "vex",
            AdapterIndex = 10,
        },
    };

    Equal(true, VpnConnectionActionPolicy.ShouldDisconnect(snapshot));
}

static void OfflineErrorRemainsReconnectable()
{
    var snapshot = new VpnConnectionSnapshot(
        VpnConnectionPhase.Error,
        "fi-1",
        Sequence: 42,
        ErrorCode: "network_unavailable")
    {
        Diagnostics = VpnTunnelDiagnostics.Empty,
    };

    Equal(false, VpnConnectionActionPolicy.ShouldDisconnect(snapshot));
}

static void ClientFailurePreservesCleanupEvidence()
{
    var connected = new VpnConnectionSnapshot(
        VpnConnectionPhase.Connected,
        "fi-1",
        Sequence: 43,
        ErrorCode: null)
    {
        Diagnostics = VpnTunnelDiagnostics.Empty with
        {
            AdapterName = "vex",
            AdapterIndex = 10,
        },
    };

    var failure = VpnConnectionSnapshot.ClientFailure(
        connected,
        "vpn_service_unavailable");

    Equal(connected.Diagnostics, failure.Diagnostics);
    Equal(true, VpnConnectionActionPolicy.ShouldDisconnect(failure));
}

static void ConnectionActionPolicyCoversEveryPhase()
{
    static VpnConnectionSnapshot Snapshot(VpnConnectionPhase phase) =>
        new(phase, "fi-1", Sequence: 44, ErrorCode: null);

    Equal(
        false,
        VpnConnectionActionPolicy.ShouldDisconnect(
            VpnConnectionSnapshot.Disconnected()));
    Equal(
        false,
        VpnConnectionActionPolicy.ShouldDisconnect(
            Snapshot(VpnConnectionPhase.Connecting)));
    Equal(
        true,
        VpnConnectionActionPolicy.ShouldDisconnect(
            Snapshot(VpnConnectionPhase.Connected)));
    Equal(
        false,
        VpnConnectionActionPolicy.ShouldDisconnect(
            Snapshot(VpnConnectionPhase.Disconnecting)));
}

static void VpnErrorCodesPreserveSafeProfileFailures()
{
    Equal(
        "profile_signature_invalid",
        VpnErrorCode.Sanitize("profile_signature_invalid"));
    Equal(
        "profile_payload_invalid",
        VpnErrorCode.Sanitize("profile_payload_invalid"));
}

static void VpnErrorCodesRejectUnsafeText()
{
    Equal(
        "tunnel_runtime_failure",
        VpnErrorCode.Sanitize("profile invalid: secret"));
    Equal(
        "tunnel_runtime_failure",
        VpnErrorCode.Sanitize(new string('a', 65)));
}

static void StaleSnapshotsAreIgnored()
{
    var initial = new VpnConnectionSnapshot(
        VpnConnectionPhase.Connected,
        "fi-1",
        Sequence: 50,
        ErrorCode: null);

    var next = VpnConnectionReducer.Reduce(
        initial,
        new VpnIntent.ServiceSnapshot(
            VpnConnectionPhase.Disconnected,
            LocationId: null,
            Sequence: 49,
            ErrorCode: null));

    Equal(initial, next);
}

static void WindowsLaunchActivationAcceptsVexguardUri()
{
    var uri = ProtocolActivationUriParser.Parse(
        "vexguard://auth/callback?code=auth-code&state=state-token");

    Equal(
        "vexguard://auth/callback?code=auth-code&state=state-token",
        uri?.AbsoluteUri);
}

static void WindowsLaunchActivationAcceptsQuotedVexUri()
{
    var uri = ProtocolActivationUriParser.Parse(
        "\"vex://auth/callback?code=auth-code&state=state-token\"");

    Equal(
        "vex://auth/callback?code=auth-code&state=state-token",
        uri?.AbsoluteUri);
}

static void WindowsLaunchActivationRejectsUnrelatedSchemes()
{
    Equal(
        null,
        ProtocolActivationUriParser.Parse(
            "https://app.vexvpn.com/auth/callback?code=auth-code"));
}

static void WindowsLaunchActivationRejectsAmbiguousArguments()
{
    Equal(
        null,
        ProtocolActivationUriParser.Parse(
            "vexguard://auth/callback?code=first vexguard://auth/callback?code=second"));
}

static void IpcRequestsEnforceProtocol()
{
    var request = VpnServiceRequest.Connect(
        requestId: "request-1",
        locationId: "fi-1",
        tunnelConfig: "[Interface]\nPrivateKey = redacted");

    Equal(VpnServiceProtocol.CurrentVersion, request.ProtocolVersion);
    Equal(VpnServiceOperation.Connect, request.Operation);
    Equal("fi-1", request.LocationId);

    Throws<ArgumentOutOfRangeException>(() =>
        _ = new VpnServiceRequest(
            "request-1",
            protocolVersion: 0,
            VpnServiceOperation.Status,
            locationId: null,
            tunnelConfig: null,
            profileAuthorization: null,
            localPrivateKey: null));
}

static void IpcLoggingRedactsTunnelConfig()
{
    const string tunnelConfigFixture = "PrivateKey = must-not-appear";
    var request = VpnServiceRequest.Connect("request-2", "fi-1", tunnelConfigFixture);

    if (request.ToString().Contains(tunnelConfigFixture, StringComparison.Ordinal))
    {
        throw new InvalidOperationException("tunnel config leaked through ToString()");
    }
}

static void IpcRejectsEmptyRequestId()
{
    Throws<ArgumentException>(() =>
        _ = VpnServiceRequest.Status(" "));
}

static void IpcConnectRequiresPayload()
{
    Throws<ArgumentException>(() =>
        _ = new VpnServiceRequest(
            "request-3",
            VpnServiceProtocol.CurrentVersion,
            VpnServiceOperation.Connect,
            locationId: null,
            tunnelConfig: null,
            profileAuthorization: null,
            localPrivateKey: null));
}

static void IpcStatusRejectsPayload()
{
    Throws<ArgumentException>(() =>
        _ = new VpnServiceRequest(
            "request-4",
            VpnServiceProtocol.CurrentVersion,
            VpnServiceOperation.Status,
            locationId: "fi-1",
            tunnelConfig: "secret",
            profileAuthorization: null,
            localPrivateKey: null));
}

static void IpcFailureRequiresError()
{
    Throws<ArgumentException>(() =>
        _ = new VpnServiceResponse(
            "request-5",
            success: false,
            VpnConnectionSnapshot.Disconnected(),
            errorCode: null));
}

static void ActiveSnapshotRequiresLocation()
{
    var current = VpnConnectionSnapshot.Disconnected(sequence: 70);
    Throws<ArgumentException>(() =>
        _ = VpnConnectionReducer.Reduce(
            current,
            new VpnIntent.ServiceSnapshot(
                VpnConnectionPhase.Connected,
                LocationId: null,
                Sequence: 71,
            ErrorCode: null)));
}

static void ServiceHandlerConnects()
{
    var runtime = new FakeVpnTunnelRuntime
    {
        ConnectResult = new VpnTunnelStatus(
            VpnConnectionPhase.Connected,
            "fi-1",
            errorCode: null),
    };
    var handler = new VpnServiceCommandHandler(runtime);

    var response = handler.HandleAsync(
        VpnServiceRequest.Connect("connect-1", "fi-1", "PrivateKey = secret"),
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(true, response.Success);
    Equal(VpnConnectionPhase.Connected, response.Snapshot.Phase);
    Equal("fi-1", response.Snapshot.LocationId);
    Equal(1, runtime.ConnectCalls);
}

static void ServiceHandlerIsIdempotent()
{
    var runtime = new FakeVpnTunnelRuntime
    {
        ConnectResult = new VpnTunnelStatus(
            VpnConnectionPhase.Connected,
            "fi-1",
            errorCode: null),
    };
    var handler = new VpnServiceCommandHandler(runtime);
    var request = VpnServiceRequest.Connect(
        "connect-retry",
        "fi-1",
        "PrivateKey = secret");

    var first = handler.HandleAsync(request, CancellationToken.None)
        .GetAwaiter().GetResult();
    var retry = handler.HandleAsync(request, CancellationToken.None)
        .GetAwaiter().GetResult();

    Equal(first, retry);
    Equal(1, runtime.ConnectCalls);
}

static void ServiceHandlerSanitizesFailures()
{
    var runtime = new FakeVpnTunnelRuntime
    {
        ConnectError = new InvalidOperationException(
            "PrivateKey = must-not-leak"),
    };
    var handler = new VpnServiceCommandHandler(runtime);

    var response = handler.HandleAsync(
        VpnServiceRequest.Connect(
            "connect-error",
            "fi-1",
            "PrivateKey = must-not-leak"),
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(false, response.Success);
    Equal("tunnel_runtime_failure", response.ErrorCode);
    if (response.ToString().Contains("must-not-leak", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("runtime failure leaked a tunnel secret");
    }
}

static void ServiceHandlerPropagatesCancellation()
{
    var runtime = new FakeVpnTunnelRuntime
    {
        ConnectError = new OperationCanceledException(),
    };
    var handler = new VpnServiceCommandHandler(runtime);

    Throws<OperationCanceledException>(() =>
        _ = handler.HandleAsync(
            VpnServiceRequest.Connect(
                "connect-cancel",
                "fi-1",
                "PrivateKey = secret"),
            CancellationToken.None).GetAwaiter().GetResult());
}

static void ServiceHandlerRejectsIdConflict()
{
    var runtime = new FakeVpnTunnelRuntime
    {
        ConnectResult = new VpnTunnelStatus(
            VpnConnectionPhase.Connected,
            "fi-1",
            errorCode: null),
    };
    var handler = new VpnServiceCommandHandler(runtime);

    _ = handler.HandleAsync(
        VpnServiceRequest.Connect("same-id", "fi-1", "config-a"),
        CancellationToken.None).GetAwaiter().GetResult();
    var conflict = handler.HandleAsync(
        VpnServiceRequest.Connect("same-id", "de-1", "config-b"),
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(false, conflict.Success);
    Equal("request_id_conflict", conflict.ErrorCode);
    Equal(1, runtime.ConnectCalls);
}

static void IpcFrameRoundTrips()
{
    var envelope = new VpnIpcRequestEnvelope(
        "0123456789abcdef0123456789abcdef",
        VpnServiceRequest.Connect(
            "frame-1",
            "fi-1",
            "[Interface]\nPrivateKey = secret"));
    using var stream = new MemoryStream();

    VpnIpcFrameCodec.WriteRequestAsync(
        stream,
        envelope,
        CancellationToken.None).GetAwaiter().GetResult();
    stream.Position = 0;
    var decoded = VpnIpcFrameCodec.ReadRequestAsync(
        stream,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(envelope.Authorization, decoded.Authorization);
    Equal(envelope.Request, decoded.Request);
}

static void IpcFrameRejectsTruncation()
{
    using var stream = new MemoryStream(
        [8, 0, 0, 0, (byte)'{', (byte)'}']);

    Throws<VpnIpcProtocolException>(() =>
        _ = VpnIpcFrameCodec.ReadRequestAsync(
            stream,
            CancellationToken.None).GetAwaiter().GetResult());
}

static void IpcFrameRejectsOversize()
{
    var oversized = VpnIpcFrameCodec.MaxFrameBytes + 1;
    using var stream = new MemoryStream(
        BitConverter.GetBytes(oversized));

    Throws<VpnIpcProtocolException>(() =>
        _ = VpnIpcFrameCodec.ReadRequestAsync(
            stream,
            CancellationToken.None).GetAwaiter().GetResult());
}

static void IpcAuthenticationIsExact()
{
    const string authProofFixture = "0123456789abcdef0123456789abcdef";
    var authenticator = new VpnIpcAuthenticator(authProofFixture);

    Equal(true, authenticator.Verify(authProofFixture));
    Equal(false, authenticator.Verify(
        "0123456789abcdef0123456789abcdee"));
}

static void IpcEnvelopeLoggingRedactsSecrets()
{
    const string authProofFixture = "0123456789abcdef0123456789abcdef";
    const string config = "PrivateKey = must-not-leak";
    var envelope = new VpnIpcRequestEnvelope(
        authProofFixture,
        VpnServiceRequest.Connect("frame-2", "fi-1", config));
    var rendered = envelope.ToString();

    if (rendered.Contains(authProofFixture, StringComparison.Ordinal) ||
        rendered.Contains(config, StringComparison.Ordinal))
    {
        throw new InvalidOperationException("IPC envelope leaked a secret");
    }
}

static void TunnelConfigAcceptsManagedProfile()
{
    const string config = """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = 10.64.1.25/32
        DNS = 1.1.1.1, 8.8.8.8
        MTU = 1360
        Jc = 4
        S1 = 64
        H1 = 123456

        [Peer]
        PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
        PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
        Endpoint = 198.51.100.10:443
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """;

    VpnTunnelConfigurationValidator.Validate(config);
}

static void TunnelConfigRejectsScripts()
{
    const string config = """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = 10.64.1.25/32
        PostUp = powershell.exe -Command whoami
        [Peer]
        PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
        Endpoint = 198.51.100.10:443
        AllowedIPs = 0.0.0.0/0
        """;

    Throws<VpnTunnelException>(() =>
        VpnTunnelConfigurationValidator.Validate(config));
}

static void TunnelConfigRejectsUnknownFields()
{
    const string config = """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = 10.64.1.25/32
        ArbitraryField = unsafe
        [Peer]
        PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
        Endpoint = 198.51.100.10:443
        AllowedIPs = 0.0.0.0/0
        """;

    Throws<VpnTunnelException>(() =>
        VpnTunnelConfigurationValidator.Validate(config));
}

static void IpcPolicyBlocksUnsignedConnect()
{
    var request = VpnServiceRequest.Connect(
        "unsigned-profile",
        "fi-1",
        "[Interface]\nPrivateKey = secret");

    Equal(false, VpnServiceAccessPolicy.IsAuthorized(request));
    Equal(
        true,
        VpnServiceAccessPolicy.IsAuthorized(
            VpnServiceRequest.Status("status")));
    Equal(
        true,
        VpnServiceAccessPolicy.IsAuthorized(
            VpnServiceRequest.TrustedConnect(
                "trusted-profile",
                new VpnProfileAuthorization(
                    "profile-key-1",
                    "ECDSA_P256_SHA256_DER",
                    Convert.ToBase64String([1]),
                    Convert.ToBase64String([2])),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")));
}

static void SignedProfileMaterializesTunnel()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var profile = verifier.Authorize(
        authorization,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");

    Equal("fi-1", profile.LocationId);
    Equal(now.AddMinutes(5), profile.ExpiresAt);
    if (!profile.TunnelConfig.Contains(
            "Endpoint = 198.51.100.10:443",
            StringComparison.Ordinal) ||
        !profile.TunnelConfig.Contains(
            "PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            StringComparison.Ordinal))
    {
        throw new InvalidOperationException("trusted tunnel config was incomplete");
    }
}

static void SignedProfileRejectsTampering()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var payload = authorization.PayloadBase64;
    var tamperedPayload = payload[..^1] +
        (payload[^1] == 'A' ? "B" : "A");
    var tampered = new VpnProfileAuthorization(
        authorization.KeyId,
        authorization.Algorithm,
        tamperedPayload,
        authorization.SignatureBase64);
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    Throws<VpnTunnelException>(() =>
        verifier.Authorize(
            tampered,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

static void SignedProfileRejectsExpiration()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var issuedAt = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, issuedAt);
    var verifier = CreateSignedProfileVerifier(
        signingKey,
        issuedAt.AddMinutes(10));

    Throws<VpnTunnelException>(() =>
        verifier.Authorize(
            authorization,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

static void SignedProfileReportsUnsupportedProtocol()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(
        signingKey,
        now,
        protocol: "wireguard");
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var error = Throws<VpnTunnelException>(() =>
        verifier.Authorize(
            authorization,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));

    Equal("profile_protocol_unsupported", error.Code);
}

static void SignedProfileIdentifiesUnknownPayloadField()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var payload = JsonNode.Parse(
        Base64UrlDecode(authorization.PayloadBase64))!.AsObject();
    payload["tunnel"]!.AsObject()["unexpected"] = true;
    var modifiedPayload = JsonSerializer.SerializeToUtf8Bytes(payload);
    var signature = signingKey.SignData(
        modifiedPayload,
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
    var modified = new VpnProfileAuthorization(
        authorization.KeyId,
        authorization.Algorithm,
        Base64Url(modifiedPayload),
        Base64Url(signature));
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var error = Throws<VpnTunnelException>(() =>
        verifier.Authorize(
            modified,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));

    Equal("profile_payload_tunnel_unexpected_invalid", error.Code);
}

static void SignedProfileIdentifiesInvalidLocalKey()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var error = Throws<VpnTunnelException>(() =>
        verifier.Authorize(authorization, "not-a-wireguard-key"));

    Equal("local_private_key_invalid", error.Code);
}

static void SignedProfileIdentifiesInvalidServerKey()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var payload = JsonNode.Parse(
        Base64UrlDecode(authorization.PayloadBase64))!.AsObject();
    payload["tunnel"]!.AsObject()["server_public_key"] = "invalid";
    var modifiedPayload = JsonSerializer.SerializeToUtf8Bytes(payload);
    var signature = signingKey.SignData(
        modifiedPayload,
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
    var modified = new VpnProfileAuthorization(
        authorization.KeyId,
        authorization.Algorithm,
        Base64Url(modifiedPayload),
        Base64Url(signature));
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var error = Throws<VpnTunnelException>(() =>
        verifier.Authorize(
            modified,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));

    Equal("profile_server_public_key_invalid", error.Code);
}

static void SignedProfileAcceptsWindowsRouteBudget()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    var authorization = CreateSignedProfileAuthorization(signingKey, now);
    var payload = JsonNode.Parse(
        Base64UrlDecode(authorization.PayloadBase64))!.AsObject();
    payload["tunnel"]!.AsObject()["allowed_ips"] = new JsonArray(
        Enumerable.Range(0, 128)
            .Select(index => JsonValue.Create($"10.{index}.0.0/16"))
            .ToArray<JsonNode?>());
    var modifiedPayload = JsonSerializer.SerializeToUtf8Bytes(payload);
    var signature = signingKey.SignData(
        modifiedPayload,
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
    var modified = new VpnProfileAuthorization(
        authorization.KeyId,
        authorization.Algorithm,
        Base64Url(modifiedPayload),
        Base64Url(signature));
    var verifier = CreateSignedProfileVerifier(signingKey, now);

    var profile = verifier.Authorize(
        modified,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");

    if (!profile.TunnelConfig.Contains(
            "AllowedIPs = 10.0.0.0/16",
            StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "the signed Windows route list was not materialized");
    }
}

static void SignedProfileAcceptsBackendLifetime()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var issuedAt = new DateTimeOffset(2026, 7, 28, 12, 0, 0, TimeSpan.Zero);
    var authorization = CreateSignedProfileAuthorization(
        signingKey,
        issuedAt,
        issuedAt.AddHours(24));
    var verifier = CreateSignedProfileVerifier(
        signingKey,
        issuedAt.AddHours(23));

    var profile = verifier.Authorize(
        authorization,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");

    Equal("fi-1", profile.LocationId);
}

static void SignedProfileRejectsInvalidSigningKey()
{
    Throws<ArgumentException>(() =>
        new VpnSignedProfileVerifier(
            [
                new VpnProfileSigningKey(
                    "profile-key-1",
                    "ECDSA_P256_SHA256_DER",
                    Convert.ToBase64String([1, 2, 3])),
            ]));
}

static void SignedProfileLoggingRedactsSecrets()
{
    const string payload = "signed-policy-payload";
    const string signature = "profile-signature";
    var authorization = new VpnProfileAuthorization(
        "profile-key-1",
        "ECDSA_P256_SHA256_DER",
        Convert.ToBase64String(Encoding.UTF8.GetBytes(payload)),
        Convert.ToBase64String(Encoding.UTF8.GetBytes(signature)));
    var rendered = authorization.ToString();

    if (rendered.Contains(payload, StringComparison.Ordinal) ||
        rendered.Contains(signature, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "signed profile logging exposed authorization material");
    }
}

static void WindowsLoginUsesDeviceSessionContract()
{
    var handler = new RecordingHttpHandler(
        """
        {
          "user":{"id":"user-1","email":"user@example.com","status":"active"},
          "session":{"access_token":"access-secret","expires_at":"2026-08-01T00:00:00Z"}
        }
        """);
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var session = client.LoginAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("access-secret", session.AccessToken);
    Equal(HttpMethod.Post, handler.Request!.Method);
    Equal("/v1/auth/login", handler.Request.RequestUri!.AbsolutePath);
    var body = handler.Body!;
    if (!body.Contains("\"remember_me\":true", StringComparison.Ordinal) ||
        !body.Contains("\"device_session\":true", StringComparison.Ordinal) ||
        body.Contains("access-secret", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("unexpected login request contract");
    }
}

static void WindowsEmailOtpRequestUsesContract()
{
    var handler = new RecordingHttpHandler(
        """
        {
          "challenge_id":"challenge-1",
          "expires_at":"2026-07-28T13:30:00Z"
        }
        """);
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var challenge = client.RequestEmailOtpAsync(
        "user@example.com",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("challenge-1", challenge.ChallengeId);
    Equal(HttpMethod.Post, handler.Request!.Method);
    Equal("/v1/auth/email-otp/request", handler.Request.RequestUri!.AbsolutePath);
    if (!handler.Body!.Contains("\"email\":\"user@example.com\"", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("unexpected otp request contract");
    }
}

static void WindowsEmailOtpConfirmUsesContract()
{
    var handler = new RecordingHttpHandler(
        """
        {
          "user":{"id":"user-1","email":"user@example.com","status":"active"},
          "session":{"access_token":"access-secret","expires_at":"2026-08-01T00:00:00Z"}
        }
        """);
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var session = client.ConfirmEmailOtpAsync(
        "user@example.com",
        "challenge-1",
        "123456",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("access-secret", session.AccessToken);
    Equal("/v1/auth/email-otp/confirm", handler.Request!.RequestUri!.AbsolutePath);
    var body = handler.Body!;
    if (!body.Contains("\"challenge_id\":\"challenge-1\"", StringComparison.Ordinal) ||
        !body.Contains("\"code\":\"123456\"", StringComparison.Ordinal) ||
        !body.Contains("\"remember_me\":true", StringComparison.Ordinal) ||
        !body.Contains("\"device_session\":true", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("unexpected otp confirm contract");
    }
}

static void WindowsEmailOtpConfirmRejectsInvalidCode()
{
    var handler = new RecordingHttpHandler("""{}""");
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    Throws<ArgumentException>(() =>
        client.ConfirmEmailOtpAsync(
            "user@example.com",
            "challenge-1",
            "12 34",
            CancellationToken.None).GetAwaiter().GetResult());

    if (handler.Request is not null)
    {
        throw new InvalidOperationException(
            "OTP confirmation sent request with invalid code.");
    }
}

static void WindowsAuthCodeExchangeUsesPkceContract()
{
    var handler = new RecordingHttpHandler(
        """
        {
          "user":{"id":"user-1","email":"user@example.com","status":"active"},
          "session":{"access_token":"access-secret","expires_at":"2026-08-01T00:00:00Z"}
        }
        """);
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });
    const string verifier =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";

    var session = client.ExchangeAppAuthCodeAsync(
        "auth-code-12345678",
        verifier,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("access-secret", session.AccessToken);
    Equal("/v1/auth/token", handler.Request!.RequestUri!.AbsolutePath);
    var body = handler.Body!;
    if (!body.Contains("\"code\":\"auth-code-12345678\"", StringComparison.Ordinal) ||
        !body.Contains($"\"code_verifier\":\"{verifier}\"", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("unexpected auth code exchange contract");
    }
}

static void WindowsPkceCallbackRejectsDuplicateQueryItems()
{
    var request = PkceAuthFlow.CreateRequest(
        new Uri("https://vexguard.app"),
        "win-installation-1",
        "Windows",
        "windows",
        WebAuthMode.Login,
        length => length == 64 ? "expected-verifier-abcdefghijklmnopqrstuvwxyzABCDEFGHJKLMN0123456789-._~" : "expected-state-1");
    var duplicateState = new Uri(
        "vexguard://auth/callback?state=expected-state-1&state=other&code=abc");
    var duplicateCode = new Uri(
        "vexguard://auth/callback?state=expected-state-1&code=abc&code=other");

    Throws<InvalidOperationException>(() =>
        PkceAuthFlow.ResolveCallback(
            duplicateState,
            request.PendingChallenge.State,
            request.PendingChallenge.Verifier));
    Throws<InvalidOperationException>(() =>
        PkceAuthFlow.ResolveCallback(
            duplicateCode,
            request.PendingChallenge.State,
            request.PendingChallenge.Verifier));
}

static void WindowsPkceCallbackRejectsPathPrefixLookalikes()
{
    Throws<InvalidOperationException>(() =>
        PkceAuthFlow.ResolveCallback(
            new Uri(
                "vexguard://auth/callback-attacker?state=expected-state-1&code=abc"),
            "expected-state-1",
            new string('v', 64)));
}

static void WindowsProfilePreservesAuthorization()
{
    var handler = new RecordingHttpHandler(
        """
        {
          "version":7,
          "device_id":"device-1",
          "authorization":{
            "key_id":"profile-key-1",
            "algorithm":"ECDSA_P256_SHA256_DER",
            "payload_base64":"cGF5bG9hZA",
            "signature_base64":"c2lnbmF0dXJl"
          }
        }
        """);
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var profile = client.GetManagedVpnProfileAsync(
        "access-secret",
        "device-1",
        "fi-1",
        "full",
        null,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("profile-key-1", profile.Authorization!.KeyId);
    Equal("Bearer", handler.Request!.Headers.Authorization!.Scheme);
    Equal("access-secret", handler.Request.Headers.Authorization.Parameter);
    var query = handler.Request.RequestUri!.Query;
    if (!query.Contains("platform=windows", StringComparison.Ordinal) ||
        !query.Contains("awg_version=3", StringComparison.Ordinal) ||
        !query.Contains("location=fi-1", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("AWG3 profile capability was not sent");
    }
}

static void WindowsProfileSendsKnownVersion()
{
    var handler = new RecordingHttpHandler(
        """{"version":7,"device_id":"device-1","unchanged":true}""");
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var profile = client.GetManagedVpnProfileAsync(
        "access-secret",
        "device-1",
        "fi-1",
        "full",
        7,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(true, profile.Unchanged);
    if (!handler.Request!.RequestUri!.Query.Contains(
            "known_version=7",
            StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "cached profile version was not sent");
    }
}

static void WindowsRegistrationUsesVerifiedDeviceIdentity()
{
    var provider = new FakeDeviceIdentityProvider();
    var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
    {
        "/v1/devices/identity-challenge" => JsonResponse(
            """
            {
              "id":"challenge-1",
              "nonce":"nonce-1",
              "purpose":"register"
            }
            """),
        "/v1/devices/register" => JsonResponse(
            """
            {
              "device":{
                "id":"device-1",
                "name":"Windows",
                "status":"active",
                "public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              }
            }
            """),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound),
    });
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        },
        provider);

    var device = client.RegisterNativeDeviceAsync(
        "access-secret",
        "win-installation-1",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        1,
        "fi-1",
        "1.0.54",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("device-1", device.Id);
    Equal(2, handler.Requests.Count);
    Equal("/v1/devices/identity-challenge", handler.Requests[0].RequestUri!.AbsolutePath);
    Equal("/v1/devices/register", handler.Requests[1].RequestUri!.AbsolutePath);
    Equal(
        "native-windows-register-win-installation-1-1-verified",
        handler.Requests[1].Headers.GetValues("Idempotency-Key").Single());

    using var challengeBody = JsonDocument.Parse(handler.Bodies[0]!);
    Equal(
        "win-installation-1",
        challengeBody.RootElement.GetProperty("installation_id").GetString());
    Equal(
        "register",
        challengeBody.RootElement.GetProperty("purpose").GetString());

    using var registerBody = JsonDocument.Parse(handler.Bodies[1]!);
    Equal(
        provider.Identity.PublicKey,
        registerBody.RootElement.GetProperty("identity_public_key").GetString());
    Equal(
        DeviceIdentity.KeyTypeP256Jwk,
        registerBody.RootElement.GetProperty("identity_key_type").GetString());
    Equal(
        "challenge-1",
        registerBody.RootElement.GetProperty("identity_challenge_id").GetString());
    var signature = registerBody.RootElement
        .GetProperty("identity_signature")
        .GetString();
    if (string.IsNullOrWhiteSpace(signature))
    {
        throw new InvalidOperationException(
            "device identity signature was not sent");
    }
    var payload = DeviceIdentity.SignaturePayload(
        "challenge-1",
        "nonce-1",
        "register",
        "win-installation-1",
        provider.Identity.PublicKey,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    if (!VerifyDeviceIdentitySignature(provider.Identity, payload, signature!))
    {
        throw new InvalidOperationException(
            "device identity signature was not DER-verifiable");
    }
}

static void WindowsRegistrationFailsClosedWithoutIdentityChallenge()
{
    var provider = new FakeDeviceIdentityProvider();
    var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
    {
        "/v1/devices/identity-challenge" => new HttpResponseMessage(HttpStatusCode.InternalServerError),
        "/v1/devices/register" => JsonResponse(
            """
            {
              "device":{
                "id":"device-1",
                "name":"Windows",
                "status":"active",
                "public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              }
            }
            """),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound),
    });
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        },
        provider);

    Throws<VexApiException>(() =>
        client.RegisterNativeDeviceAsync(
            "access-secret",
            "win-installation-1",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            1,
            "fi-1",
            "1.0.54",
            CancellationToken.None).GetAwaiter().GetResult());

    Equal(1, handler.Requests.Count);
    Equal(
        "/v1/devices/identity-challenge",
        handler.Requests[0].RequestUri!.AbsolutePath);
}

static void WindowsBillingSummaryUsesContracts()
{
    var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
    {
        "/v1/billing/plans" => JsonResponse(
            """
            [
              {
                "id":"pro_monthly",
                "name":"Pro",
                "provider":"platega",
                "amount_cents":49900,
                "currency":"RUB",
                "interval":"monthly",
                "device_limit":3,
                "tier":"pro",
                "status":"active"
              }
            ]
            """),
        "/v1/billing/entitlement" => JsonResponse(
            """
            {
              "active":true,
              "plan_id":"pro_monthly",
              "display_name":"Pro",
              "status":"active",
              "tier":"pro",
              "vpn_access":true
            }
            """),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound),
    });
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var summary = client.GetBillingSummaryAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("Управление подпиской", summary.Title);
    Equal("pro_monthly", summary.CurrentPlan!.Id);
    Equal("Активен", summary.CurrentPlan.Action == "Текущий" ? "Активен" : "Не активен");
    Equal(2, handler.Requests.Count);
    Equal("Bearer", handler.Requests[1].Headers.Authorization!.Scheme);
}

static void WindowsBillingCheckoutUsesContract()
{
    var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
    {
        "/v1/billing/checkout-session" => JsonResponse(
            """
            {
              "id":"checkout-1",
              "plan_id":"pro_monthly",
              "provider":"platega",
              "url":"https://payments.example.test/checkout-1",
              "status":"open"
            }
            """),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound),
    });
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var session = client.CreateCheckoutSessionAsync(
        "access-secret",
        "pro_monthly",
        null,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("checkout-1", session.Id);
    Equal(HttpMethod.Post, handler.Requests[0].Method);
    if (!handler.Bodies[0]!.Contains("\"plan_id\":\"pro_monthly\"", StringComparison.Ordinal) ||
        !handler.Bodies[0]!.Contains("\"provider\":\"platega\"", StringComparison.Ordinal) ||
        !handler.Bodies[0]!.Contains("\"return_url\":\"https://api.example.test/\"", StringComparison.Ordinal) ||
        !handler.Bodies[0]!.Contains("\"failed_url\":\"https://api.example.test/\"", StringComparison.Ordinal) ||
        handler.Requests[0].Headers.Authorization?.Parameter != "access-secret")
    {
        throw new InvalidOperationException("unexpected billing checkout request contract");
    }
}

static void WindowsSupportHistoryUsesContract()
{
    var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
    {
        "/v1/support-tickets" when request.Method == HttpMethod.Get => JsonResponse(
            """
            [
              {
                "id":"ticket-1",
                "subject":"Не подключается",
                "message":"Первое сообщение",
                "messages":[
                  {
                    "id":"message-1",
                    "ticket_id":"ticket-1",
                    "sender":"user",
                    "body":"Первое сообщение",
                    "created_at":"2026-07-28T10:00:00Z"
                  },
                  {
                    "id":"message-2",
                    "ticket_id":"ticket-1",
                    "sender":"admin",
                    "body":"Проверьте DNS",
                    "created_at":"2026-07-28T10:03:00Z"
                  }
                ],
                "status":"waiting_user",
                "priority":"normal",
                "source":"windows_native",
                "created_at":"2026-07-28T10:00:00Z",
                "updated_at":"2026-07-28T10:03:00Z"
              }
            ]
            """),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound),
    });
    var client = new VexApiClient(
        new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });

    var tickets = client.GetSupportTicketsAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(1, tickets.Count);
    Equal("ticket-1", tickets[0].Id);
    Equal("Не подключается", tickets[0].Subject);
    Equal("waiting_user", tickets[0].Status);
    Equal(2, tickets[0].Messages.Count);
    Equal("admin", tickets[0].Messages[1].Sender);
    Equal("access-secret", handler.Requests[0].Headers.Authorization?.Parameter);
}

static void WindowsControlPlaneExposesParityReads()
{
    static VexApiClient Client(string response, out RecordingHttpHandler handler)
    {
        handler = new RecordingHttpHandler(response);
        return new VexApiClient(new HttpClient(handler)
        {
            BaseAddress = new Uri("https://api.example.test"),
        });
    }

    var meClient = Client(
        """{"id":"user-1","email":"user@example.com","status":"active"}""",
        out var meHandler);
    var user = meClient.GetCurrentUserAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("user-1", user.Id);
    Equal("/v1/auth/me", meHandler.Request!.RequestUri!.AbsolutePath);

    var paymentClient = Client(
        """
        [{"id":"payment-1","provider":"platega","amount_minor":49900,
          "currency":"RUB","method":"card","status":"succeeded",
          "created_at":"2026-07-30T10:00:00Z"}]
        """,
        out var paymentHandler);
    var payments = paymentClient.GetBillingPaymentsAsync(
        "access-secret",
        24,
        CancellationToken.None).GetAwaiter().GetResult();
    Equal(1, payments.Count);
    Equal("?limit=24", paymentHandler.Request!.RequestUri!.Query);

    var devicesClient = Client(
        """
        [{"id":"device-1","name":"Windows","status":"active",
          "public_key":"public-key","platform":"windows"}]
        """,
        out var devicesHandler);
    var devices = devicesClient.GetDevicesAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("windows", devices[0].Platform);
    Equal("/v1/devices", devicesHandler.Request!.RequestUri!.AbsolutePath);

    var usageClient = Client(
        """
        {"usage":[{"device_id":"device-1","connection_status":"connected",
          "connected":true,"seconds_since_handshake":5,
          "rx_bytes":10,"tx_bytes":20,"total_bytes":30}]}
        """,
        out var usageHandler);
    var usage = usageClient.GetDeviceUsageAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();
    Equal(30L, usage[0].TotalBytes);
    Equal("/v1/devices/usage", usageHandler.Request!.RequestUri!.AbsolutePath);
}

static void WindowsControlPlaneSendsTelemetryAndDiagnostics()
{
    var handler = new RecordingHttpHandler("""{}""");
    var client = new VexApiClient(new HttpClient(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    client.ReportVpnConnectAsync(
        "access-secret",
        new VpnConnectionTelemetry("device-1", 7, "amneziawg", "manual"),
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("/v1/vpn/connect", handler.Request!.RequestUri!.AbsolutePath);
    if (!handler.Body!.Contains("\"profile_version\":7", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("connect telemetry payload is incomplete");
    }

    handler = new RecordingHttpHandler("""{}""");
    client = new VexApiClient(new HttpClient(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    client.ReportVpnDisconnectAsync(
        "access-secret",
        new VpnConnectionTelemetry("device-1", 7, "amneziawg", "user"),
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("/v1/vpn/disconnect", handler.Request!.RequestUri!.AbsolutePath);

    handler = new RecordingHttpHandler("""{}""");
    client = new VexApiClient(new HttpClient(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    client.SubmitClientDiagnosticsAsync(
        "access-secret",
        new ClientDiagnosticsReport(
            "device-1", "windows", "1.0.54", "manual", "ok",
            "connected", "198.51.100.1:51820", true, true, 12.5,
            10, 20, new Dictionary<string, string> { ["source"] = "settings" }),
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("/v1/diagnostics/client", handler.Request!.RequestUri!.AbsolutePath);
    if (!handler.Body!.Contains("\"latency_avg_ms\":12.5", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("diagnostics payload is incomplete");
    }
}

static void WindowsControlPlaneExposesSupportAndAppConfiguration()
{
    var supportHandler = new RecordingHttpHandler("""{"ticket":"socket-ticket"}""");
    var supportClient = new VexApiClient(new HttpClient(supportHandler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    var socketUri = supportClient.GetSupportWebSocketUriAsync(
        "access-secret",
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("wss", socketUri.Scheme);
    Equal("?ticket=socket-ticket", socketUri.Query);

    var metadata = new ClientAppMetadata(
        "windows", "1.0.54", 54, "stable", "1.0.0",
        "Windows 11", "arm64", "native-windows-1", 1);
    var configHandler = new RecordingHttpHandler(
        """{"version":"1","routing_policy_version":"2026.07.1","incident_banner":"ok"}""");
    var configClient = new VexApiClient(new HttpClient(configHandler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    var config = configClient.GetRemoteConfigAsync(
        metadata,
        CancellationToken.None).GetAwaiter().GetResult();
    Equal("2026.07.1", config.RoutingPolicyVersion);

    var updateHandler = new RecordingHttpHandler(
        """
        {"update_available":true,"required":false,"latest_version":"1.0.55",
         "latest_build":55,"min_supported_build":50,
         "download_url":"https://downloads.example.test/vex.msix"}
        """);
    var updateClient = new VexApiClient(new HttpClient(updateHandler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    var update = updateClient.CheckForAppUpdateAsync(
        metadata,
        CancellationToken.None).GetAwaiter().GetResult();
    Equal(true, update.UpdateAvailable);
    Equal("1.0.55", update.LatestVersion);
}

static void WindowsProfilePreservesRoutingPreferences()
{
    var handler = new RecordingHttpHandler(
        """{"version":7,"device_id":"device-1","unchanged":true}""");
    var client = new VexApiClient(new HttpClient(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
    });
    client.GetManagedVpnProfileAsync(
        "access-secret", "device-1", "se-1", "split", "ru", 7,
        CancellationToken.None).GetAwaiter().GetResult();

    var query = handler.Request!.RequestUri!.Query;
    if (!query.Contains("routing_mode=split", StringComparison.Ordinal) ||
        !query.Contains("bypass_region=ru", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("routing preferences were lost");
    }
}

static void WireGuardIdentityGeneratesKeys()
{
    var first = WireGuardIdentity.Generate();
    var second = WireGuardIdentity.Generate();

    Equal(32, Convert.FromBase64String(first.PrivateKey).Length);
    Equal(32, Convert.FromBase64String(first.PublicKey).Length);
    if (first.PrivateKey == second.PrivateKey ||
        first.PublicKey == second.PublicKey)
    {
        throw new InvalidOperationException("generated identities repeated");
    }
}

static void NativeClientProvisionsAndConnects()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54",
        () => new DateTimeOffset(2026, 7, 28, 12, 0, 0, TimeSpan.Zero));

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(1, api.RegisterCalls);
    Equal(1, api.ProfileCalls);
    Equal("profile-key-1", vpn.Authorization!.KeyId);
    Equal(store.State!.Identity.PrivateKey, vpn.PrivateKey);
}

static void NativeClientProvisionsPreAuthenticatedSession()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    var session = new VexAuthSession(
        new VexUser("user-1", "user@example.com", "active"),
        "access-secret",
        new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero));

    coordinator.ProvisionAuthenticatedSessionAsync(
        session,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(1, api.RegisterCalls);
    Equal("user@example.com", store.State!.Session.User.Email);
}

static void NativeClientReusesUnchangedProfile()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(1, api.ProfileCalls);
    Equal(null, api.KnownVersions[0]);
    Equal("profile-key-1", vpn.Authorization!.KeyId);
}

static void NativeClientReusesCachedProfileAfterTimeout()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    api.ProfileRequestTimesOut = true;
    vpn.Authorization = null;

    var response = coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(true, response.Success);
    Equal("profile-key-1", vpn.Authorization!.KeyId);
}

static void NativeClientReconnectsFromCacheWithoutControlPlane()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    var entitlementCalls = api.EntitlementCalls;
    var profileCalls = api.ProfileCalls;
    vpn.Authorization = null;

    var response = coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(true, response.Success);
    Equal(entitlementCalls, api.EntitlementCalls);
    Equal(profileCalls, api.ProfileCalls);
    Equal("profile-key-1", vpn.Authorization!.KeyId);
}

static void NativeClientScopesCachedAuthorityToTarget()
{
    var api = new FakeNativeClientApi
    {
        Locations =
        [
            new VpnLocation("fi-1", "Helsinki", "available", 1),
            new VpnLocation("de-1", "Frankfurt", "available", 1),
        ],
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    var profileCalls = api.ProfileCalls;
    store.Save(store.State! with { LocationId = "de-1" });

    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(profileCalls + 1, api.ProfileCalls);
    Equal(null, api.KnownVersions[^1]);
    Equal("de-1", api.ProfileLocationIds[^1]);
}

static void NativeClientPreservesWorkingProfileOnTargetFailure()
{
    var api = new FakeNativeClientApi
    {
        Locations =
        [
            new VpnLocation("fi-1", "Helsinki", "available", 1),
            new VpnLocation("de-1", "Frankfurt", "available", 1),
        ],
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    var previousAuthorization = store.State!.CachedAuthorization;
    api.ProfileRequestTimesOut = true;

    Throws<TaskCanceledException>(() =>
        coordinator.ConnectAsync(
                "de-1",
                "full",
                CancellationToken.None)
            .GetAwaiter()
            .GetResult());

    Equal("fi-1", store.State!.LocationId);
    Equal(previousAuthorization, store.State.CachedAuthorization);
}

static void NativeClientRecoversFromCorruptedProfileCache()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    store.Save(store.State! with
    {
        CachedProfileVersion = 2,
    });

    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(2, api.ProfileCalls);
    Equal(null, api.KnownVersions[0]);
    Equal(null, api.KnownVersions[1]);
    Equal("profile-key-1", vpn.Authorization!.KeyId);
}

static void NativeClientRefreshesExpiringSessionAtBoundary()
{
    var fixedNow = new DateTimeOffset(2026, 7, 28, 12, 0, 0, TimeSpan.Zero);
    var api = new FakeNativeClientApi
    {
        RefreshThrowsIfCalled = false,
        RefreshResult = new VexAuthSession(
            new VexUser("user-1", "user@example.com", "active"),
            "refreshed-token",
            fixedNow.AddHours(1)),
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54",
        () => fixedNow);

    var identity = WireGuardIdentity.Generate();
    store.Save(new NativeClientState(
        new VexAuthSession(
            new VexUser("user-1", "user@example.com", "active"),
            "expiring-token",
            fixedNow.AddMinutes(5)),
        "win-installation-1",
        "device-1",
        "fi-1",
        identity));

    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter().GetResult();

    Equal(1, api.RefreshCalls);
    Equal("refreshed-token", store.State!.Session.AccessToken);
}

static void NativeClientRotatesExpiredKey()
{
    var api = new FakeNativeClientApi
    {
        RotationRequiredOnce = true,
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();

    Equal(1, api.RotateCalls);
    Equal(2, store.State!.Identity.KeyEpoch);
    Equal(store.State.Identity.PrivateKey, vpn.PrivateKey);
}

static void NativeClientPreservesManualVpnPreferences()
{
    var api = new FakeNativeClientApi
    {
        Locations =
        [
            new VpnLocation("fi-1", "Helsinki", "available", 1),
            new VpnLocation("se-1", "Stockholm", "available", 1),
        ],
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api, store, vpn, "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    Equal(2, coordinator.GetLocationsAsync(CancellationToken.None)
        .GetAwaiter().GetResult().Count);
    coordinator.SelectLocationAsync(
        "se-1",
        reconnectIfConnected: false,
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.ConnectAsync(
        null,
        "split",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("se-1", store.State!.LocationId);
    Equal("manual", store.State.SelectionMode);
    Equal("split", store.State.RoutingMode);
    Equal("se-1", api.ProfileLocationIds[^1]);
    Equal("split", api.ProfileRoutingModes[^1]);
}

static void NativeClientGatesConnectOnEntitlement()
{
    var api = new FakeNativeClientApi
    {
        Entitlement = FakeNativeClientApi.NoVpnEntitlement,
    };
    var coordinator = new NativeClientCoordinator(
        api,
        new MemoryClientStateStore(),
        new FakeVpnControlClient(),
        "1.0.54");
    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();

    var error = Throws<NativeClientFlowException>(() =>
        coordinator.ConnectAsync(
            null,
            "full",
            CancellationToken.None).GetAwaiter().GetResult());
    Equal("vpn_entitlement_required", error.Code);
    Equal(0, api.ProfileCalls);
}

static void NativeClientReportsVpnLifecycle()
{
    var api = new FakeNativeClientApi();
    var coordinator = new NativeClientCoordinator(
        api,
        new MemoryClientStateStore(),
        new FakeVpnControlClient(),
        "1.0.54");
    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();

    coordinator.ConnectAsync(
        null,
        "full",
        CancellationToken.None).GetAwaiter().GetResult();
    coordinator.DisconnectAsync(
        "user",
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(1, api.ConnectReportCalls);
    Equal(1, api.DisconnectReportCalls);
    Equal("user", api.DisconnectReasons[0]);
}

static void NativeClientRepliesThroughActiveSupportThread()
{
    var api = new FakeNativeClientApi
    {
        SupportTickets =
        new List<SupportTicket>
        {
            new SupportTicket(
                "ticket-1",
                "Не подключается",
                "Первое сообщение",
                new[]
                {
                    new SupportMessage(
                        "message-1",
                        "ticket-1",
                        "user",
                        null,
                        "Первое сообщение",
                        "2026-07-28T10:00:00Z"),
                },
                "open",
                "normal",
                "windows_native",
                null,
                "2026-07-28T10:00:00Z",
                "2026-07-28T10:00:00Z",
                null),
        },
    };
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    var snapshot = coordinator.GetSupportSnapshotAsync(
        CancellationToken.None).GetAwaiter().GetResult();
    var ticket = coordinator.SendSupportMessageAsync(
        "Проверьте еще раз, пожалуйста.",
        null,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal("ticket-1", snapshot.ActiveTicket!.Id);
    Equal(1, snapshot.Tickets.Count);
    Equal(1, api.SupportCreateCalls);
    Equal("Не подключается", api.SupportSubjects[0]);
    Equal("Проверьте еще раз, пожалуйста.", api.SupportBodies[0]);
    Equal(2, ticket.Messages.Count);
}

static void NativeClientDerivesSupportSubjectForNewThread()
{
    var api = new FakeNativeClientApi();
    var store = new MemoryClientStateStore();
    var vpn = new FakeVpnControlClient();
    var coordinator = new NativeClientCoordinator(
        api,
        store,
        vpn,
        "1.0.54");

    coordinator.SignInAndProvisionAsync(
        "user@example.com",
        "correct horse battery staple",
        CancellationToken.None).GetAwaiter().GetResult();
    var ticket = coordinator.SendSupportMessageAsync(
        "Не подключается после обновления\nЛоги приложил ниже.",
        null,
        CancellationToken.None).GetAwaiter().GetResult();

    Equal(1, api.SupportCreateCalls);
    Equal("Не подключается после обновления", api.SupportSubjects[0]);
    Equal("Не подключается после обновления", ticket.Subject);
}

static VpnProfileAuthorization CreateSignedProfileAuthorization(
    ECDsa signingKey,
    DateTimeOffset issuedAt,
    DateTimeOffset? expiresAt = null,
    string protocol = "amneziawg")
{
    var policy = new
    {
        schema = "vex.native-vpn-profile.v1",
        profile_version = 7,
        user_id = "user-1",
        device_id = "device-1",
        requested_location_id = "fi-1",
        assigned_location_id = "fi-1",
        routing_mode = "full",
        bypass_region = "",
        routing_policy_version = "full-v1",
        issued_at = issuedAt,
        expires_at = expiresAt ?? issuedAt.AddMinutes(5),
        tunnel = new
        {
            protocol,
            endpoint = "198.51.100.10:443",
            server_public_key = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
            preshared_key = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
            assigned_ipv4 = "10.64.1.25/32",
            dns = new[] { "1.1.1.1", "8.8.8.8" },
            allowed_ips = new[] { "0.0.0.0/0", "::/0" },
            mtu = 1360,
            persistent_keepalive = 25,
            amnezia = new
            {
                jc = 4,
                jmin = 40,
                jmax = 70,
                s1 = 64,
                s2 = 96,
                i1 = "<b 0x01020304>",
                i2 = "",
            },
        },
    };
    var payload = JsonSerializer.SerializeToUtf8Bytes(policy);
    var signature = signingKey.SignData(
        payload,
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
    return new VpnProfileAuthorization(
        "profile-key-1",
        "ECDSA_P256_SHA256_DER",
        Base64Url(payload),
        Base64Url(signature));
}

static string Base64Url(byte[] value) =>
    Convert.ToBase64String(value)
        .TrimEnd('=')
        .Replace('+', '-')
        .Replace('/', '_');

static bool VerifyDeviceIdentitySignature(
    DeviceIdentity identity,
    string payload,
    string signatureBase64Url)
{
    using var ecdsa = ECDsa.Create(new ECParameters
    {
        Curve = ECCurve.NamedCurves.nistP256,
        Q = new ECPoint
        {
            X = identity.ExportPublicX(),
            Y = identity.ExportPublicY(),
        },
    });
    return ecdsa.VerifyData(
        Encoding.UTF8.GetBytes(payload),
        Base64UrlDecode(signatureBase64Url),
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
}

static byte[] Base64UrlDecode(string value)
{
    var normalized = value.Replace('-', '+').Replace('_', '/');
    var remainder = normalized.Length % 4;
    if (remainder != 0)
    {
        normalized = normalized.PadRight(
            normalized.Length + (4 - remainder),
            '=');
    }

    return Convert.FromBase64String(normalized);
}

static VpnSignedProfileVerifier CreateSignedProfileVerifier(
    ECDsa signingKey,
    DateTimeOffset now) =>
    new(
        [
            new VpnProfileSigningKey(
                "profile-key-1",
                "ECDSA_P256_SHA256_DER",
                Convert.ToBase64String(
                    signingKey.ExportSubjectPublicKeyInfo())),
        ],
        () => now);

static WindowsUpdateAssessment VerifyRollbackManifest(
    ECDsa signingKey,
    long manifestRevision,
    string requiredVersionFloor,
    WindowsUpdateRollbackState? rollbackState = null)
{
    var payload = $$"""
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "manifest_revision": {{manifestRevision}},
          "required_version_floor": "{{requiredVersionFloor}}",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "3.0.0.0",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/VEX.Native.msix",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": null,
              "package_size_bytes": 1024,
              "minimum_supported_version": "1.0.0.0",
              "changelog": null,
              "required": true,
              "rollout_percent": 100,
              "install_entrypoint": "elevated_bootstrap",
              "service_ownership": "manual_sc_bootstrap",
              "raw_msix_provisions_service": false,
              "raw_appinstaller_provisions_service": false,
              "bootstrap_uri": "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/bootstrap-native-windows.ps1",
              "bootstrap_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "bootstrap_size_bytes": 100,
              "install_service_script_uri": "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/install-vpn-service.ps1",
              "install_service_script_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "install_service_script_size_bytes": 100,
              "uninstall_service_script_uri": "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/uninstall-vpn-service.ps1",
              "uninstall_service_script_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "uninstall_service_script_size_bytes": 100,
              "package_metadata_uri": "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/package-metadata.json",
              "package_metadata_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_metadata_size_bytes": 100
            }
          ]
        }
        """;
    var bytes = Encoding.UTF8.GetBytes(payload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            bytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    return WindowsUpdateManifestVerifier.Verify(
        bytes,
        signature,
        new WindowsUpdateVerificationOptions(
            new Uri(
                "https://downloads.vexguard.app/windows/native/",
                UriKind.Absolute),
            "stable",
            "x64",
            "1.0.0.0",
            new WindowsUpdateKeyring(
                WindowsUpdateConstants.KeyringSchema,
                [
                    new WindowsUpdatePublicKey(
                        "native-update-p256-v1",
                        WindowsUpdateConstants.SupportedAlgorithm,
                        Convert.ToBase64String(
                            signingKey.ExportSubjectPublicKeyInfo())),
                ]),
            RollbackState: rollbackState,
            UtcNow: () => DateTimeOffset.Parse(
                "2026-07-28T13:00:00Z")));
}

static void WindowsUpdaterRejectsManifestRevisionReplay()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var accepted = VerifyRollbackManifest(
        signingKey,
        manifestRevision: 12,
        requiredVersionFloor: "2.0.0.0");
    var reloadedState = JsonSerializer.Deserialize<
        WindowsUpdateRollbackState>(
        JsonSerializer.Serialize(accepted.RollbackState)) ??
        throw new InvalidOperationException(
            "persisted rollback state did not reload");

    Throws<InvalidOperationException>(() =>
        VerifyRollbackManifest(
            signingKey,
            manifestRevision: 11,
            requiredVersionFloor: "2.0.0.0",
            rollbackState: reloadedState));
}

static void WindowsUpdaterRejectsRequiredVersionFloorDecrease()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var accepted = VerifyRollbackManifest(
        signingKey,
        manifestRevision: 12,
        requiredVersionFloor: "2.5.0.0");

    Throws<InvalidOperationException>(() =>
        VerifyRollbackManifest(
            signingKey,
            manifestRevision: 13,
            requiredVersionFloor: "2.4.9.9",
            rollbackState: accepted.RollbackState));
}

static WindowsUpdateRelease WithTestProvisioningArtifacts(
    WindowsUpdateRelease release,
    byte[] artifactBytes)
{
    var hash = Convert.ToHexString(SHA256.HashData(artifactBytes));
    var root = release.PackageUri[..(
        release.PackageUri.LastIndexOf(
            "/",
            StringComparison.Ordinal) + 1)];
    return release with
    {
        InstallEntrypoint = "elevated_bootstrap",
        ServiceOwnership = "manual_sc_bootstrap",
        RawMsixProvisionsService = false,
        RawAppinstallerProvisionsService = false,
        BootstrapUri = root + "bootstrap-native-windows.ps1",
        BootstrapSha256 = hash,
        BootstrapSizeBytes = artifactBytes.Length,
        InstallServiceScriptUri = root + "install-vpn-service.ps1",
        InstallServiceScriptSha256 = hash,
        InstallServiceScriptSizeBytes = artifactBytes.Length,
        UninstallServiceScriptUri = root + "uninstall-vpn-service.ps1",
        UninstallServiceScriptSha256 = hash,
        UninstallServiceScriptSizeBytes = artifactBytes.Length,
        PackageMetadataUri = root + "package-metadata.json",
        PackageMetadataSha256 = hash,
        PackageMetadataSizeBytes = artifactBytes.Length,
    };
}

static string AddSignedUpdateSecurityMetadata(
    string json,
    long manifestRevision = 100,
    string requiredVersionFloor = "1.0.0.0")
{
    var root = JsonNode.Parse(json)?.AsObject() ??
        throw new InvalidOperationException("test update manifest is invalid");
    root["manifest_revision"] = manifestRevision;
    root["required_version_floor"] = requiredVersionFloor;
    foreach (var releaseNode in root["releases"]?.AsArray() ??
             throw new InvalidOperationException(
                 "test update manifest releases are missing"))
    {
        var release = releaseNode?.AsObject() ??
            throw new InvalidOperationException(
                "test update release is invalid");
        var packageUri = release["package_uri"]?.GetValue<string>() ??
            throw new InvalidOperationException(
                "test update package URI is missing");
        var artifactRoot = packageUri[..(
            packageUri.LastIndexOf(
                "/",
                StringComparison.Ordinal) + 1)];
        const string hash =
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
        release["install_entrypoint"] = "elevated_bootstrap";
        release["service_ownership"] = "manual_sc_bootstrap";
        release["raw_msix_provisions_service"] = false;
        release["raw_appinstaller_provisions_service"] = false;
        release["bootstrap_uri"] =
            artifactRoot + "bootstrap-native-windows.ps1";
        release["bootstrap_sha256"] = hash;
        release["bootstrap_size_bytes"] = 100;
        release["install_service_script_uri"] =
            artifactRoot + "install-vpn-service.ps1";
        release["install_service_script_sha256"] = hash;
        release["install_service_script_size_bytes"] = 100;
        release["uninstall_service_script_uri"] =
            artifactRoot + "uninstall-vpn-service.ps1";
        release["uninstall_service_script_sha256"] = hash;
        release["uninstall_service_script_size_bytes"] = 100;
        release["package_metadata_uri"] =
            artifactRoot + "package-metadata.json";
        release["package_metadata_sha256"] = hash;
        release["package_metadata_size_bytes"] = 100;
    }

    return root.ToJsonString();
}

static void WindowsUpdaterAcceptsSignedManifest()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var payload = """
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "1.2.3.4",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/1.2.3.4/x64/VEX.Native.stable.x64.1.2.3.4.msix",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": "https://downloads.vexguard.app/windows/native/stable/x64/VEX.Native.stable.x64.appinstaller",
              "package_size_bytes": 1024,
              "minimum_supported_version": "1.0.0.0",
              "changelog": "Security fixes",
              "required": true,
              "rollout_percent": 100
            }
          ]
        }
        """;
    payload = AddSignedUpdateSecurityMetadata(payload);
    var bytes = Encoding.UTF8.GetBytes(payload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            bytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var options = new WindowsUpdateVerificationOptions(
        new Uri("https://downloads.vexguard.app/windows/native/", UriKind.Absolute),
        "production",
        "amd64",
        "1.2.3.3",
        new WindowsUpdateKeyring(
            WindowsUpdateConstants.KeyringSchema,
            [
                new WindowsUpdatePublicKey(
                    "native-update-p256-v1",
                    WindowsUpdateConstants.SupportedAlgorithm,
                    Convert.ToBase64String(
                        signingKey.ExportSubjectPublicKeyInfo())),
            ]),
        UtcNow: UpdateFixtureNow);

    var assessment = WindowsUpdateManifestVerifier.Verify(
        bytes,
        signature,
        options);

    Equal(true, assessment.UpdateAvailable);
    Equal("required_update_available", assessment.Reason);
    Equal("1.2.3.4", assessment.Release?.Version);
}

static void WindowsUpdaterHonorsStagedRollout()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var payload = """
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "1.2.3.4",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/1.2.3.4/x64/VEX.Native.msix",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": null,
              "package_size_bytes": 1024,
              "minimum_supported_version": null,
              "changelog": null,
              "required": false,
              "rollout_percent": 10
            }
          ]
        }
        """;
    payload = AddSignedUpdateSecurityMetadata(payload);
    var bytes = Encoding.UTF8.GetBytes(payload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            bytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var options = new WindowsUpdateVerificationOptions(
        new Uri("https://downloads.vexguard.app/windows/native/", UriKind.Absolute),
        "stable",
        "x64",
        "1.2.3.3",
        new WindowsUpdateKeyring(
            WindowsUpdateConstants.KeyringSchema,
            [
                new WindowsUpdatePublicKey(
                    "native-update-p256-v1",
                    WindowsUpdateConstants.SupportedAlgorithm,
                    Convert.ToBase64String(
                        signingKey.ExportSubjectPublicKeyInfo())),
            ]),
        RolloutBucket: 42,
        UtcNow: UpdateFixtureNow);

    var assessment = WindowsUpdateManifestVerifier.Verify(
        bytes,
        signature,
        options);

    Equal(false, assessment.UpdateAvailable);
    Equal("rollout_not_selected", assessment.Reason);
}

static void WindowsUpdaterRejectsTamperedManifest()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var signedPayload = AddSignedUpdateSecurityMetadata(
        """
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "1.2.3.4",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/1.2.3.4/x64/VEX.Native.stable.x64.1.2.3.4.msix",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": "https://downloads.vexguard.app/windows/native/stable/x64/VEX.Native.stable.x64.appinstaller",
              "package_size_bytes": 1024,
              "minimum_supported_version": "1.0.0.0",
              "changelog": null,
              "required": false,
              "rollout_percent": 100
            }
          ]
        }
        """);
    var signedBytes = Encoding.UTF8.GetBytes(signedPayload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            signedBytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var tamperedBytes = Encoding.UTF8.GetBytes(
        Encoding.UTF8.GetString(signedBytes).Replace(
            "1.2.3.4",
            "1.2.3.5",
            StringComparison.Ordinal));

    Throws<InvalidOperationException>(() =>
        WindowsUpdateManifestVerifier.Verify(
            tamperedBytes,
            signature,
            new WindowsUpdateVerificationOptions(
                new Uri("https://downloads.vexguard.app/windows/native/", UriKind.Absolute),
                "stable",
                "x64",
                "1.2.3.3",
                new WindowsUpdateKeyring(
                    WindowsUpdateConstants.KeyringSchema,
                    [
                        new WindowsUpdatePublicKey(
                            "native-update-p256-v1",
                            WindowsUpdateConstants.SupportedAlgorithm,
                            Convert.ToBase64String(
                                signingKey.ExportSubjectPublicKeyInfo())),
                    ]))));
}

static void WindowsUpdaterStagesAndReusesPackage()
{
    var packageBytes = Encoding.UTF8.GetBytes("signed-msix-payload");
    var provisioningBytes = Encoding.UTF8.GetBytes("signed-provisioning-payload");
    var packageHash = Convert.ToHexString(SHA256.HashData(packageBytes));
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var manifest = $$"""
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "2.0.0.0",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/2.0.0.0/x64/VEX.Native.stable.x64.2.0.0.0.msix",
              "package_sha256": "{{packageHash}}",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": "https://downloads.vexguard.app/windows/native/stable/x64/VEX.Native.stable.x64.appinstaller",
              "package_size_bytes": {{packageBytes.Length}},
              "minimum_supported_version": "1.0.0.0",
              "changelog": "Atomic staging",
              "required": false,
              "rollout_percent": 100
            }
          ]
        }
        """;
    manifest = AddSignedUpdateSecurityMetadata(manifest);
    var manifestBytes = Encoding.UTF8.GetBytes(manifest);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            manifestBytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var keyring = new WindowsUpdateKeyring(
        WindowsUpdateConstants.KeyringSchema,
        [
            new WindowsUpdatePublicKey(
                "native-update-p256-v1",
                WindowsUpdateConstants.SupportedAlgorithm,
                Convert.ToBase64String(signingKey.ExportSubjectPublicKeyInfo())),
        ]);
    var handler = new FakeHttpMessageHandler(request =>
    {
        if (request.RequestUri?.AbsoluteUri.EndsWith("update.json", StringComparison.Ordinal) == true)
        {
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(manifestBytes),
            };
        }

        if (request.RequestUri?.AbsoluteUri.EndsWith("update.json.sig", StringComparison.Ordinal) == true)
        {
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(signature, Encoding.UTF8, "text/plain"),
            };
        }

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(
                request.RequestUri?.AbsolutePath.EndsWith(
                    ".msix",
                    StringComparison.OrdinalIgnoreCase) == true
                    ? packageBytes
                    : provisioningBytes),
        };
    });
    using var httpClient = new HttpClient(handler);
    var coordinator = new WindowsUpdateCoordinator(
        httpClient,
        new WindowsUpdateVerificationOptions(
            new Uri("https://downloads.vexguard.app/windows/native/", UriKind.Absolute),
            "stable",
            "x64",
            "1.0.0.0",
            keyring,
            UtcNow: UpdateFixtureNow),
        new Uri("https://downloads.vexguard.app/windows/native/stable/x64/update.json", UriKind.Absolute),
        new Uri("https://downloads.vexguard.app/windows/native/stable/x64/update.json.sig", UriKind.Absolute));

    var assessment = coordinator.CheckForUpdateAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    Equal(true, assessment.UpdateAvailable);
    var stagingRoot = Path.Combine(
        Path.GetTempPath(),
        $"vex-native-update-tests-{Guid.NewGuid():N}");
    try
    {
        var release = WithTestProvisioningArtifacts(
            assessment.Release!,
            provisioningBytes);
        var first = coordinator.DownloadAndStageProvisioningAsync(
            release,
            stagingRoot,
            CancellationToken.None)
            .GetAwaiter()
            .GetResult();
        Equal(true, File.Exists(first.PackagePath));
        Equal(true, File.Exists(first.BootstrapPath));

        var beforeReuseCalls = handler.Requests.Count;
        var second = coordinator.DownloadAndStageProvisioningAsync(
            release,
            stagingRoot,
            CancellationToken.None)
            .GetAwaiter()
            .GetResult();
        Equal(first.PackagePath, second.PackagePath);
        Equal(beforeReuseCalls, handler.Requests.Count);
    }
    finally
    {
        if (Directory.Exists(stagingRoot))
        {
            Directory.Delete(stagingRoot, recursive: true);
        }
    }
}

static void WindowsUpdaterRedownloadsCachedPackageWhenHashMismatched()
{
    var packageBytes = Encoding.UTF8.GetBytes("signed-msix-payload");
    var provisioningBytes = Encoding.UTF8.GetBytes("signed-provisioning-payload");
    var packageHash = Convert.ToHexString(SHA256.HashData(packageBytes));
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var manifest = $$"""
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "2.0.0.0",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/2.0.0.0/x64/VEX.Native.stable.x64.2.0.0.0.msix",
              "package_sha256": "{{packageHash}}",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": "https://downloads.vexguard.app/windows/native/stable/x64/VEX.Native.stable.x64.appinstaller",
              "package_size_bytes": {{packageBytes.Length}},
              "minimum_supported_version": "1.0.0.0",
              "changelog": "Atomic staging",
              "required": false,
              "rollout_percent": 100
            }
          ]
        }
        """;
    manifest = AddSignedUpdateSecurityMetadata(manifest);
    var manifestBytes = Encoding.UTF8.GetBytes(manifest);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            manifestBytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var keyring = new WindowsUpdateKeyring(
        WindowsUpdateConstants.KeyringSchema,
        [
            new WindowsUpdatePublicKey(
                "native-update-p256-v1",
                WindowsUpdateConstants.SupportedAlgorithm,
                Convert.ToBase64String(signingKey.ExportSubjectPublicKeyInfo())),
        ]);
    var handler = new FakeHttpMessageHandler(request =>
    {
        if (request.RequestUri?.AbsoluteUri.EndsWith("update.json", StringComparison.Ordinal) == true)
        {
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(manifestBytes),
            };
        }

        if (request.RequestUri?.AbsoluteUri.EndsWith("update.json.sig", StringComparison.Ordinal) == true)
        {
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(signature, Encoding.UTF8, "text/plain"),
            };
        }

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(
                request.RequestUri?.AbsolutePath.EndsWith(
                    ".msix",
                    StringComparison.OrdinalIgnoreCase) == true
                    ? packageBytes
                    : provisioningBytes),
        };
    });
    using var httpClient = new HttpClient(handler);
    var coordinator = new WindowsUpdateCoordinator(
        httpClient,
        new WindowsUpdateVerificationOptions(
            new Uri("https://downloads.vexguard.app/windows/native/", UriKind.Absolute),
            "stable",
            "x64",
            "1.0.0.0",
            keyring,
            UtcNow: UpdateFixtureNow),
        new Uri("https://downloads.vexguard.app/windows/native/stable/x64/update.json", UriKind.Absolute),
        new Uri("https://downloads.vexguard.app/windows/native/stable/x64/update.json.sig", UriKind.Absolute));

    var assessment = coordinator.CheckForUpdateAsync(CancellationToken.None)
        .GetAwaiter()
        .GetResult();
    Equal(true, assessment.UpdateAvailable);

    var stagingRoot = Path.Combine(
        Path.GetTempPath(),
        $"vex-native-update-tests-{Guid.NewGuid():N}");
    Directory.CreateDirectory(stagingRoot);
    var stalePath = Path.Combine(
        stagingRoot,
        "x64",
        "2.0.0.0",
        "VEX.Native.stable.x64.2.0.0.0.msix");
    Directory.CreateDirectory(Path.GetDirectoryName(stalePath)!);
    File.WriteAllBytes(stalePath, Encoding.UTF8.GetBytes("stale-payload"));
    try
    {
        var beforePackageFetch = handler.Requests.Count;
        var staged = coordinator.DownloadAndStageProvisioningAsync(
            WithTestProvisioningArtifacts(
                assessment.Release!,
                provisioningBytes),
            stagingRoot,
            CancellationToken.None)
            .GetAwaiter()
            .GetResult();

        Equal(true, File.Exists(staged.BootstrapPath));
        if (!File.Exists(stalePath))
        {
            throw new InvalidOperationException("stale package should have been repaired in place");
        }

        var finalPayload = File.ReadAllText(stalePath);
        if (finalPayload != "signed-msix-payload")
        {
            throw new InvalidOperationException(
                "stale package content should be replaced on hash mismatch");
        }

        Equal(beforePackageFetch + 5, handler.Requests.Count);
    }
    finally
    {
        if (Directory.Exists(stagingRoot))
        {
            Directory.Delete(stagingRoot, recursive: true);
        }
    }
}

static void WindowsUpdaterRejectsUnexpectedPackageSize()
{
    var packageBytes = Encoding.UTF8.GetBytes("oversized-package");
    var release = new WindowsUpdateRelease(
        Version: "3.0.0.0",
        Architecture: "x64",
        PackageType: "msix",
        PackageUri:
            "https://downloads.vexguard.app/windows/native/stable/3.0.0.0/x64/VEX.Native.msix",
        PackageSha256:
            Convert.ToHexString(SHA256.HashData(packageBytes)),
        PackageName: "VEX.Native.Windows",
        Publisher: "CN=VEX",
        AppInstallerUri: null,
        PackageSizeBytes: packageBytes.Length - 1,
        MinimumSupportedVersion: null,
        Changelog: null,
        Required: false,
        RolloutPercent: 100);
    using var httpClient = new HttpClient(
        new FakeHttpMessageHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(packageBytes),
            }));
    var coordinator = new WindowsUpdateCoordinator(
        httpClient,
        new WindowsUpdateVerificationOptions(
            new Uri(
                "https://downloads.vexguard.app/windows/native/",
                UriKind.Absolute),
            "stable",
            "x64",
            "1.0.0.0",
            new WindowsUpdateKeyring(
                WindowsUpdateConstants.KeyringSchema,
                [])),
        new Uri(
            "https://downloads.vexguard.app/windows/native/stable/x64/update.json"),
        new Uri(
            "https://downloads.vexguard.app/windows/native/stable/x64/update.json.sig"));
    var stagingRoot = Path.Combine(
        Path.GetTempPath(),
        $"vex-native-update-size-tests-{Guid.NewGuid():N}");

    try
    {
        InvalidOperationException? rejection = null;
        try
        {
            coordinator.DownloadAndStageProvisioningAsync(
                release,
                stagingRoot,
                CancellationToken.None)
                .GetAwaiter()
                .GetResult();
        }
        catch (InvalidOperationException error)
        {
            rejection = error;
        }

        Equal(
            "Windows update package size did not match the signed manifest.",
            rejection?.Message);
    }
    finally
    {
        if (Directory.Exists(stagingRoot))
        {
            Directory.Delete(stagingRoot, recursive: true);
        }
    }
}

static void WindowsUpdaterRejectsOversizedManifest()
{
    var oversizedManifest = new byte[WindowsUpdateConstants.MaxManifestBytes + 1];
    using var httpClient = new HttpClient(
        new FakeHttpMessageHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(oversizedManifest),
            }));
    var coordinator = new WindowsUpdateCoordinator(
        httpClient,
        new WindowsUpdateVerificationOptions(
            new Uri(
                "https://downloads.vexguard.app/windows/native/",
                UriKind.Absolute),
            "stable",
            "x64",
            "1.0.0.0",
            new WindowsUpdateKeyring(
                WindowsUpdateConstants.KeyringSchema,
                [])),
        new Uri(
            "https://downloads.vexguard.app/windows/native/stable/x64/update.json"),
        new Uri(
            "https://downloads.vexguard.app/windows/native/stable/x64/update.json.sig"));

    var message = string.Empty;
    try
    {
        _ = coordinator.CheckForUpdateAsync(CancellationToken.None)
            .GetAwaiter()
            .GetResult();
    }
    catch (InvalidOperationException error)
    {
        message = error.Message;
    }

    Equal(
        "Windows update manifest exceeded the maximum allowed size.",
        message);
}

static void WindowsUpdaterRejectsExecutablePackageUri()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var payload = """
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-28T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "1.2.3.4",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/1.2.3.4/x64/VEX.Native.exe",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": null,
              "package_size_bytes": 1024,
              "minimum_supported_version": null,
              "changelog": null,
              "required": false,
              "rollout_percent": 100
            }
          ]
        }
        """;
    payload = AddSignedUpdateSecurityMetadata(payload);
    var bytes = Encoding.UTF8.GetBytes(payload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            bytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));

    var message = string.Empty;
    try
    {
        _ = WindowsUpdateManifestVerifier.Verify(
            bytes,
            signature,
            new WindowsUpdateVerificationOptions(
                new Uri(
                    "https://downloads.vexguard.app/windows/native/",
                    UriKind.Absolute),
                "stable",
                "x64",
                "1.0.0.0",
                new WindowsUpdateKeyring(
                    WindowsUpdateConstants.KeyringSchema,
                    [
                        new WindowsUpdatePublicKey(
                            "native-update-p256-v1",
                            WindowsUpdateConstants.SupportedAlgorithm,
                            Convert.ToBase64String(
                                signingKey.ExportSubjectPublicKeyInfo())),
                    ]),
                UtcNow: UpdateFixtureNow));
    }
    catch (InvalidOperationException error)
    {
        message = error.Message;
    }

    Equal(
        "Windows update package_uri must reference an .msix package.",
        message);
}

static DateTimeOffset UpdateFixtureNow() =>
    DateTimeOffset.Parse(
        "2026-07-28T12:30:00Z",
        System.Globalization.CultureInfo.InvariantCulture);

static void WindowsUpdaterRejectsStaleSignedManifest()
{
    using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var payload = """
        {
          "schema": "vex.windows-update-manifest.v1",
          "channel": "stable",
          "published_at": "2026-07-01T12:00:00Z",
          "signing": {
            "key_id": "native-update-p256-v1",
            "algorithm": "ECDSA_P256_SHA256_DER"
          },
          "releases": [
            {
              "version": "1.2.3.4",
              "architecture": "x64",
              "package_type": "msix",
              "package_uri": "https://downloads.vexguard.app/windows/native/stable/1.2.3.4/x64/VEX.Native.msix",
              "package_sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              "package_name": "VEX.Native.Windows",
              "publisher": "CN=VEX",
              "appinstaller_uri": null,
              "package_size_bytes": 1024,
              "minimum_supported_version": null,
              "changelog": null,
              "required": false,
              "rollout_percent": 100
            }
          ]
        }
        """;
    payload = AddSignedUpdateSecurityMetadata(payload);
    var bytes = Encoding.UTF8.GetBytes(payload);
    var signature = Convert.ToBase64String(
        signingKey.SignData(
            bytes,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));
    var keyring = new WindowsUpdateKeyring(
        WindowsUpdateConstants.KeyringSchema,
        [
            new WindowsUpdatePublicKey(
                "native-update-p256-v1",
                WindowsUpdateConstants.SupportedAlgorithm,
                Convert.ToBase64String(
                    signingKey.ExportSubjectPublicKeyInfo())),
        ]);

    var message = string.Empty;
    try
    {
        _ = WindowsUpdateManifestVerifier.Verify(
            bytes,
            signature,
            new WindowsUpdateVerificationOptions(
                new Uri(
                    "https://downloads.vexguard.app/windows/native/",
                    UriKind.Absolute),
                "stable",
                "x64",
                "1.0.0.0",
                keyring,
                UtcNow: () => new DateTimeOffset(
                    2026,
                    7,
                    29,
                    12,
                    0,
                    0,
                    TimeSpan.Zero)));
    }
    catch (InvalidOperationException error)
    {
        message = error.Message;
    }

    Equal("Windows update manifest is stale.", message);
}

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"expected <{expected}> but received <{actual}>");
    }
}

static TException Throws<TException>(Action action)
    where TException : Exception
{
    try
    {
        action();
    }
    catch (TException error)
    {
        return error;
    }

    throw new InvalidOperationException($"expected {typeof(TException).Name}");
}

static HttpResponseMessage JsonResponse(string body) =>
    new(HttpStatusCode.OK)
    {
        Content = new StringContent(
            body,
            Encoding.UTF8,
            "application/json"),
    };

sealed class FakeHttpMessageHandler(
    Func<HttpRequestMessage, HttpResponseMessage> responder)
    : HttpMessageHandler
{
    public List<string> Requests { get; } = [];

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Requests.Add(request.RequestUri?.AbsoluteUri ?? string.Empty);
        return Task.FromResult(responder(request));
    }
}

sealed class RealtimeHttpHandler : HttpMessageHandler
{
    public string? AuthorizationScheme { get; private set; }

    public string? AuthorizationParameter { get; private set; }

    public string? AcceptMediaType { get; private set; }

    public string? RequestPath { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        AuthorizationScheme = request.Headers.Authorization?.Scheme;
        AuthorizationParameter = request.Headers.Authorization?.Parameter;
        AcceptMediaType = request.Headers.Accept.SingleOrDefault()?.MediaType;
        RequestPath = request.RequestUri?.AbsolutePath;
        var payload =
            "event: customer.change\n" +
            "id: devices:9\n" +
            "data: {\"domain\":\"devices\",\"version\":9}\n\n";
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    payload,
                    Encoding.UTF8,
                    "text/event-stream"),
            });
    }
}

sealed class FakeVpnTunnelRuntime : IVpnTunnelRuntime
{
    public int ConnectCalls { get; private set; }

    public VpnTunnelStatus ConnectResult { get; init; } =
        VpnTunnelStatus.Disconnected();

    public Exception? ConnectError { get; init; }

    public Task<VpnTunnelStatus> GetStatusAsync(CancellationToken cancellationToken) =>
        Task.FromResult(VpnTunnelStatus.Disconnected());

    public Task<VpnTunnelStatus> ConnectAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        CancellationToken cancellationToken)
    {
        ConnectCalls += 1;
        if (ConnectError is not null)
        {
            return Task.FromException<VpnTunnelStatus>(ConnectError);
        }

        return Task.FromResult(ConnectResult);
    }

    public Task<VpnTunnelStatus> DisconnectAsync(CancellationToken cancellationToken) =>
        Task.FromResult(VpnTunnelStatus.Disconnected());
}

sealed class RecordingHttpHandler : HttpMessageHandler
{
    private readonly string _response;

    public RecordingHttpHandler(string response)
    {
        _response = response;
    }

    public HttpRequestMessage? Request { get; private set; }

    public string? Body { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Request = request;
        Body = request.Content?.ReadAsStringAsync(cancellationToken)
            .GetAwaiter()
            .GetResult();
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    _response,
                    Encoding.UTF8,
                    "application/json"),
            });
    }
}

sealed class RoutingHttpHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _respond;

    public RoutingHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        _respond = respond;
    }

    public List<HttpRequestMessage> Requests { get; } = [];

    public List<string?> Bodies { get; } = [];

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Requests.Add(request);
        Bodies.Add(request.Content?.ReadAsStringAsync(cancellationToken)
            .GetAwaiter()
            .GetResult());
        return Task.FromResult(_respond(request));
    }
}

sealed class MemoryClientStateStore : IClientStateStore
{
    public ClientStateAccessKind GetAccessState() =>
        State is null
            ? ClientStateAccessKind.Missing
            : ClientStateAccessKind.Available;

    public string GetOrCreateInstallationId() => "win-installation-1";

    public NativeDeviceState? LoadDevice() =>
        State is null
            ? null
            : new NativeDeviceState(
                State.InstallationId,
                State.DeviceId,
                State.LocationId,
                State.Identity);

    public NativeClientState? State { get; private set; }

    public NativeClientState? Load() => State;

    public void Save(NativeClientState state) => State = state;

    public void Clear() => State = null;
}

sealed class FakeVpnControlClient : IVpnControlClient
{
    public VpnProfileAuthorization? Authorization { get; set; }

    public string? PrivateKey { get; private set; }

    public Task<VpnServiceResponse> GetStatusAsync(
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VpnServiceResponse(
                "request-status",
                true,
                Authorization is null
                    ? VpnConnectionSnapshot.Disconnected()
                    : new VpnConnectionSnapshot(
                        VpnConnectionPhase.Connected,
                        "fi-1",
                        1,
                        null),
                null));

    public Task<VpnServiceResponse> ConnectAsync(
        VpnProfileAuthorization authorization,
        string privateKey,
        CancellationToken cancellationToken)
    {
        Authorization = authorization;
        PrivateKey = privateKey;
        return Task.FromResult(
            new VpnServiceResponse(
                "request-1",
                true,
                new VpnConnectionSnapshot(
                    VpnConnectionPhase.Connected,
                    "fi-1",
                    1,
                    null),
                null));
    }

    public Task<VpnServiceResponse> DisconnectAsync(
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VpnServiceResponse(
                "request-2",
                true,
                VpnConnectionSnapshot.Disconnected(),
                null));
}

sealed class FakeDeviceIdentityProvider : IDeviceIdentityProvider
{
    public DeviceIdentity Identity { get; } = DeviceIdentity.Generate();

    public Task<DeviceIdentity?> GetOrCreateAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<DeviceIdentity?>(Identity);
    }
}

sealed class FakeNativeClientApi : INativeClientApi
{
    public static VexEntitlement NoVpnEntitlement { get; } =
        new(
            false, null, null, "inactive", null, null, null,
            "inactive", null, null, null, false);

    public bool RotationRequiredOnce { get; init; }

    public bool RefreshThrowsIfCalled { get; init; } = true;

    public bool ProfileRequestTimesOut { get; set; }

    public VexAuthSession? RefreshResult { get; init; }

    public int RegisterCalls { get; private set; }

    public int ProfileCalls { get; private set; }

    public int EntitlementCalls { get; private set; }

    public List<int?> KnownVersions { get; } = [];

    public List<string> ProfileLocationIds { get; } = [];

    public List<string> ProfileRoutingModes { get; } = [];

    public List<string?> ProfileBypassRegions { get; } = [];

    public int RotateCalls { get; private set; }

    public List<SupportTicket> SupportTickets { get; set; } = [];

    public int SupportCreateCalls { get; private set; }

    public int RefreshCalls { get; private set; }

    public List<string> SupportSubjects { get; } = [];

    public List<string> SupportBodies { get; } = [];

    public IReadOnlyList<VpnLocation> Locations { get; init; } =
        [new VpnLocation("fi-1", "Helsinki", "available", 1)];

    public VexEntitlement Entitlement { get; init; } =
        new(
            true, "pro_monthly", "Pro", "active", "Pro", "Pro",
            "Осталось 30 дней", "active", "pro",
            "2026-08-31T00:00:00Z", "2026-08-31T00:00:00Z", true);

    public int ConnectReportCalls { get; private set; }

    public int DisconnectReportCalls { get; private set; }

    public List<string> DisconnectReasons { get; } = [];

    public Task<VexUser> GetCurrentUserAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VexUser("user-1", "user@example.com", "active"));

    public Task<VexAuthSession> LoginAsync(
        string email,
        string password,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VexAuthSession(
                new VexUser("user-1", email, "active"),
                "access-secret",
                new DateTimeOffset(2099, 8, 1, 0, 0, 0, TimeSpan.Zero)));

    public Task<EmailOtpChallenge> RequestEmailOtpAsync(
        string email,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new EmailOtpChallenge(
                "challenge-1",
                new DateTimeOffset(2026, 7, 28, 13, 30, 0, TimeSpan.Zero)));

    public Task<VexAuthSession> ConfirmEmailOtpAsync(
        string email,
        string challengeId,
        string code,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VexAuthSession(
                new VexUser("user-1", email, "active"),
                "access-secret",
                new DateTimeOffset(2099, 8, 1, 0, 0, 0, TimeSpan.Zero)));

    public Task<VexAuthSession> ExchangeAppAuthCodeAsync(
        string code,
        string codeVerifier,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VexAuthSession(
                new VexUser("user-1", "user@example.com", "active"),
                "access-secret",
                new DateTimeOffset(2099, 8, 1, 0, 0, 0, TimeSpan.Zero)));

    public Task<VexAuthSession> RefreshSessionAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        if (RefreshThrowsIfCalled)
        {
            throw new InvalidOperationException("refresh not expected");
        }

        RefreshCalls += 1;
        return Task.FromResult(
            RefreshResult ??
            throw new InvalidOperationException("refresh response is missing"));
    }

    public Task<IReadOnlyList<VpnLocation>> GetLocationsAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(Locations);

    public Task<VpnDevice> RegisterNativeDeviceAsync(
        string accessToken,
        string installationId,
        string publicKey,
        int keyEpoch,
        string locationId,
        string appVersion,
        CancellationToken cancellationToken)
    {
        RegisterCalls += 1;
        return Task.FromResult(
            new VpnDevice("device-1", "Windows", "active", publicKey));
    }

    public Task<ManagedVpnProfile> GetManagedVpnProfileAsync(
        string accessToken,
        string deviceId,
        string locationId,
        string routingMode,
        string? bypassRegion,
        int? knownVersion,
        CancellationToken cancellationToken)
    {
        ProfileCalls += 1;
        KnownVersions.Add(knownVersion);
        ProfileLocationIds.Add(locationId);
        ProfileRoutingModes.Add(routingMode);
        ProfileBypassRegions.Add(bypassRegion);
        if (ProfileRequestTimesOut)
        {
            throw new TaskCanceledException("profile request timed out");
        }
        if (knownVersion is { } version && version > 0)
        {
            return Task.FromResult(
                new ManagedVpnProfile(
                    1,
                    deviceId,
                    false,
                    false,
                    null,
                    true));
        }

        return Task.FromResult(
            new ManagedVpnProfile(
                1,
                deviceId,
                false,
                RotationRequiredOnce && ProfileCalls == 1,
                new ManagedVpnProfileAuthorization(
                    "profile-key-1",
                    "ECDSA_P256_SHA256_DER",
                    Convert.ToBase64String(
                            Encoding.UTF8.GetBytes(
                                JsonSerializer.Serialize(new
                                {
                                    profile_version = 1,
                                    device_id = deviceId,
                                    requested_location_id = locationId,
                                    routing_mode = routingMode,
                                    bypass_region = bypassRegion ?? string.Empty,
                                })))
                        .TrimEnd('=')
                        .Replace('+', '-')
                        .Replace('/', '_'),
                    "c2lnbmF0dXJl")));
    }

    public Task<VpnDevice> RotateManagedVpnKeyAsync(
        string accessToken,
        string deviceId,
        WireGuardIdentity identity,
        CancellationToken cancellationToken)
    {
        RotateCalls += 1;
        return Task.FromResult(
            new VpnDevice(
                deviceId,
                "Windows",
                "active",
                identity.PublicKey));
    }

    public Task<VexEntitlement> GetBillingEntitlementAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        EntitlementCalls += 1;
        return Task.FromResult(Entitlement);
    }

    public Task<BillingSummary> GetBillingSummaryAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            BillingSummaryBuilder.Build(
                [
                    new BillingPlan(
                        "pro_monthly",
                        "Pro",
                        "platega",
                        49900,
                        "RUB",
                        "monthly",
                        3,
                        "pro",
                        "active"),
                ],
                new VexEntitlement(
                    true,
                    "pro_monthly",
                    "Pro",
                    "active",
                    "Pro",
                    "Pro",
                    "Осталось 30 дней",
                    "active",
                    "pro",
                    "2026-08-31T00:00:00Z",
                    "2026-08-31T00:00:00Z",
                    true)));

    public Task<CheckoutSession> CreateCheckoutSessionAsync(
        string accessToken,
        string planId,
        string? provider,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new CheckoutSession(
                "checkout-1",
                planId,
                provider ?? "platega",
                "https://payments.example.test/checkout-1",
                "open"));

    public Task<BillingPortalSession> GetBillingPortalSessionAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new BillingPortalSession(
                "portal-1",
                "platega",
                "https://payments.example.test/portal-1",
                "2026-07-28T12:00:00Z"));

    public Task<VexEntitlement> CancelSubscriptionAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new VexEntitlement(
                false,
                "pro_monthly",
                "Pro",
                "active",
                "Pro",
                "Pro",
                "Отключено автопродление",
                "canceled",
                "pro",
                "2026-08-31T00:00:00Z",
                "2026-08-31T00:00:00Z",
                true));

    public Task<IReadOnlyList<BillingPayment>> GetBillingPaymentsAsync(
        string accessToken,
        int limit,
        CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<BillingPayment>>([]);

    public Task<IReadOnlyList<VpnDevice>> GetDevicesAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<VpnDevice>>([]);

    public Task<IReadOnlyList<VpnDeviceUsage>> GetDeviceUsageAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<VpnDeviceUsage>>([]);

    public Task ReportVpnConnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken)
    {
        ConnectReportCalls += 1;
        return Task.CompletedTask;
    }

    public Task ReportVpnDisconnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken)
    {
        DisconnectReportCalls += 1;
        DisconnectReasons.Add(telemetry.Reason);
        return Task.CompletedTask;
    }

    public Task SubmitClientDiagnosticsAsync(
        string accessToken,
        ClientDiagnosticsReport report,
        CancellationToken cancellationToken) =>
        Task.CompletedTask;

    public Task<IReadOnlyList<SupportTicket>> GetSupportTicketsAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<SupportTicket>>(SupportTickets);

    public Task<SupportTicket> CreateSupportTicketAsync(
        string accessToken,
        string subject,
        string message,
        string source,
        CancellationToken cancellationToken)
    {
        SupportCreateCalls += 1;
        SupportSubjects.Add(subject);
        SupportBodies.Add(message);
        var active = SupportTickets.FirstOrDefault(ticket =>
            ticket.Status is not ("closed" or "resolved"));
        var now = "2026-07-28T10:05:00Z";
        if (active is not null)
        {
            var updated = active with
            {
                Message = message,
                Messages = active.Messages
                    .Concat(
                    [
                    new SupportMessage(
                        $"message-{active.Messages.Count + 1}",
                        active.Id,
                        "user",
                        null,
                        message,
                        now),
                    ])
                    .ToArray(),
                UpdatedAt = now,
                Status = "open",
            };
            SupportTickets = SupportTickets
                .Select(ticket => ticket.Id == updated.Id ? updated : ticket)
                .ToList();
            return Task.FromResult(updated);
        }

        var created = new SupportTicket(
            "ticket-1",
            subject,
            message,
            new[]
            {
                new SupportMessage(
                    "message-1",
                    "ticket-1",
                    "user",
                    null,
                    message,
                    now),
            },
            "open",
            "normal",
            source,
            null,
            now,
            now,
            null);
        SupportTickets = SupportTickets
            .Concat([created])
            .ToList();
        return Task.FromResult(created);
    }

    public Task<Uri> GetSupportWebSocketUriAsync(
        string accessToken,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new Uri("wss://api.example.test/v1/support-ws?ticket=fake"));

    public Task<AppRemoteConfig> GetRemoteConfigAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new AppRemoteConfig(
                "1", null, null, "windows", "stable", null, null,
                null, null, 1, null, "2026.07.1", null, null));

    public Task<AppUpdateCheckResult> CheckForAppUpdateAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new AppUpdateCheckResult(
                false, false, metadata.AppVersion, metadata.BuildNumber,
                metadata.BuildNumber, string.Empty));
}

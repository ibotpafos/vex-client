using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Session;

public interface IClientStateStore
{
    ClientStateAccessKind GetAccessState();

    string GetOrCreateInstallationId();

    NativeDeviceState? LoadDevice();

    NativeClientState? Load();

    void Save(NativeClientState state);

    void Clear();
}

public enum ClientStateAccessKind
{
    Missing,
    Available,
    Locked,
}

public interface IVpnControlClient
{
    Task<VpnServiceResponse> GetStatusAsync(
        CancellationToken cancellationToken);

    Task<VpnServiceResponse> ConnectAsync(
        VpnProfileAuthorization authorization,
        string privateKey,
        CancellationToken cancellationToken);

    Task<VpnServiceResponse> ConnectAsync(
        VpnProfileAuthorization authorization,
        string privateKey,
        bool antiLeakEnabled,
        CancellationToken cancellationToken) =>
        ConnectAsync(
            authorization,
            privateKey,
            cancellationToken);

    Task<VpnServiceResponse> DisconnectAsync(
        CancellationToken cancellationToken);
}

public sealed record NativeClientState(
    VexAuthSession Session,
    string InstallationId,
    string DeviceId,
    string LocationId,
    WireGuardIdentity Identity,
    WireGuardIdentity? PendingIdentity = null,
    int? CachedProfileVersion = null,
    ManagedVpnProfileAuthorization? CachedAuthorization = null,
    string SelectionMode = "auto",
    string RoutingMode = "full",
    string? BypassRegion = null);

public sealed record NativeDeviceState(
    string InstallationId,
    string DeviceId,
    string LocationId,
    WireGuardIdentity Identity);

public sealed record NativeAccountSnapshot(
    string Email,
    string LocationId,
    VexEntitlement Entitlement,
    BillingSummary BillingSummary,
    IReadOnlyList<VpnDevice> Devices,
    IReadOnlyList<VpnDeviceUsage> DeviceUsage,
    IReadOnlyList<BillingPayment> Payments);

public sealed record NativeSupportSnapshot(
    IReadOnlyList<SupportTicket> Tickets,
    SupportTicket? ActiveTicket);

public sealed class NativeClientFlowException : Exception
{
    public NativeClientFlowException(string code)
        : base(code)
    {
        Code = code;
    }

    public string Code { get; }
}

public sealed class NativeClientCoordinator
{
    private static readonly TimeSpan RefreshWindow =
        TimeSpan.FromMinutes(5);

    private readonly INativeClientApi _api;
    private readonly IClientStateStore _stateStore;
    private readonly IVpnControlClient _vpnClient;
    private readonly string _appVersion;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public NativeClientCoordinator(
        INativeClientApi api,
        IClientStateStore stateStore,
        IVpnControlClient vpnClient,
        string appVersion,
        Func<DateTimeOffset>? utcNow = null)
    {
        _api = api;
        _stateStore = stateStore;
        _vpnClient = vpnClient;
        _appVersion = appVersion;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
    }

    public NativeClientState? CurrentState => _stateStore.Load();

    public ClientStateAccessKind CurrentStateAccess =>
        _stateStore.GetAccessState();

    public async Task<NativeClientState> ForceRefreshSessionAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            var session = await _api.RefreshSessionAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var refreshed = state with { Session = session };
            _stateStore.Save(refreshed);
            return refreshed;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<IReadOnlyList<VpnLocation>> GetLocationsAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(
                RequireCurrentState(),
                cancellationToken).ConfigureAwait(false);
            return await _api.GetLocationsAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SelectLocationAsync(
        string locationId,
        bool reconnectIfConnected,
        CancellationToken cancellationToken)
    {
        ValidatePreference(locationId, nameof(locationId));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(
                RequireCurrentState(),
                cancellationToken).ConfigureAwait(false);
            var locations = await _api.GetLocationsAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            if (!locations.Any(location =>
                    string.Equals(
                        location.Id,
                        locationId,
                        StringComparison.Ordinal)))
            {
                throw new NativeClientFlowException(
                    "vpn_location_unavailable");
            }

            _stateStore.Save(state with
            {
                LocationId = locationId,
                SelectionMode = "manual",
                CachedProfileVersion = null,
                CachedAuthorization = null,
            });
        }
        finally
        {
            _gate.Release();
        }

        if (reconnectIfConnected)
        {
            var status = await _vpnClient.GetStatusAsync(
                cancellationToken).ConfigureAwait(false);
            if (status.Snapshot.Phase == VpnConnectionPhase.Connected)
            {
                await _vpnClient.DisconnectAsync(cancellationToken)
                    .ConfigureAwait(false);
                await ConnectAsync(
                    locationId,
                    CurrentState?.RoutingMode ?? "full",
                    cancellationToken).ConfigureAwait(false);
            }
        }
    }

    public async Task SetRoutingPreferencesAsync(
        string routingMode,
        string? bypassRegion,
        CancellationToken cancellationToken)
    {
        ValidateRoutingMode(routingMode);
        bypassRegion = NormalizeBypassRegion(routingMode, bypassRegion);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            _stateStore.Save(state with
            {
                RoutingMode = routingMode,
                BypassRegion = bypassRegion,
                CachedProfileVersion = null,
                CachedAuthorization = null,
            });
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<NativeClientState> SignInAndProvisionAsync(
        string email,
        string password,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var session = await _api.LoginAsync(
                email,
                password,
                cancellationToken).ConfigureAwait(false);
            return await ProvisionAuthenticatedSessionCoreAsync(
                session,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<NativeClientState> ProvisionAuthenticatedSessionAsync(
        VexAuthSession session,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await ProvisionAuthenticatedSessionCoreAsync(
                session,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<VpnServiceResponse> ConnectAsync(
        CancellationToken cancellationToken) =>
        await ConnectAsync(
            locationId: null,
            routingMode: CurrentState?.RoutingMode ?? "full",
            antiLeakEnabled: true,
            cancellationToken).ConfigureAwait(false);

    public async Task<VpnServiceResponse> ConnectAsync(
        string? locationId,
        string routingMode,
        CancellationToken cancellationToken) =>
        await ConnectAsync(
            locationId,
            routingMode,
            antiLeakEnabled: true,
            cancellationToken).ConfigureAwait(false);

    public async Task<VpnServiceResponse> ConnectAsync(
        string? locationId,
        string routingMode,
        bool antiLeakEnabled,
        CancellationToken cancellationToken)
    {
        ValidateRoutingMode(routingMode);
        if (locationId is not null)
        {
            ValidatePreference(locationId, nameof(locationId));
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            state = await CompletePendingRotationAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            if (locationId is not null &&
                !string.Equals(
                    state.LocationId,
                    locationId,
                    StringComparison.Ordinal))
            {
                var locations = await _api.GetLocationsAsync(
                    state.Session.AccessToken,
                    cancellationToken).ConfigureAwait(false);
                if (!locations.Any(candidate =>
                        string.Equals(
                            candidate.Id,
                            locationId,
                            StringComparison.Ordinal)))
                {
                    throw new NativeClientFlowException(
                        "vpn_location_unavailable");
                }

                state = state with
                {
                    LocationId = locationId,
                    SelectionMode = "manual",
                };
            }

            var bypassRegion = NormalizeBypassRegion(
                routingMode,
                state.BypassRegion);
            if (!string.Equals(
                    state.RoutingMode,
                    routingMode,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    state.BypassRegion,
                    bypassRegion,
                    StringComparison.Ordinal))
            {
                state = state with
                {
                    RoutingMode = routingMode,
                    BypassRegion = bypassRegion,
                };
            }

            if (state.PendingIdentity is null &&
                state.CachedProfileVersion is > 0 &&
                state.CachedAuthorization is not null &&
                CachedAuthorizationMatchesTarget(state))
            {
                var cachedResponse = await _vpnClient.ConnectAsync(
                    state.CachedAuthorization!.ToServiceAuthorization(),
                    state.Identity.PrivateKey,
                    antiLeakEnabled,
                    cancellationToken).ConfigureAwait(false);
                if (cachedResponse.Success)
                {
                    _stateStore.Save(state);
                    _ = ReportCachedConnectAsync(state);
                    return cachedResponse;
                }

                if (!string.Equals(
                        cachedResponse.ErrorCode,
                        "profile_expired",
                        StringComparison.Ordinal))
                {
                    return cachedResponse;
                }

                state = state with
                {
                    CachedProfileVersion = null,
                    CachedAuthorization = null,
                };
            }

            var entitlement = await _api.GetBillingEntitlementAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            if (!entitlement.HasPaidAccess)
            {
                throw new NativeClientFlowException(
                    "vpn_entitlement_required");
            }

            var cachedAuthorizationMatchesTarget =
                state.CachedAuthorization is not null &&
                state.CachedProfileVersion is > 0 &&
                CachedAuthorizationMatchesTarget(state);
            ManagedVpnProfile profile;
            try
            {
                profile = await _api.GetManagedVpnProfileAsync(
                    state.Session.AccessToken,
                    state.DeviceId,
                    state.LocationId,
                    state.RoutingMode,
                    state.BypassRegion,
                    !cachedAuthorizationMatchesTarget
                        ? null
                        : state.CachedProfileVersion,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (
                !cancellationToken.IsCancellationRequested &&
                cachedAuthorizationMatchesTarget &&
                error is HttpRequestException
                    or IOException
                    or TaskCanceledException)
            {
                // A previously verified signed profile remains safe for the
                // service to validate. This keeps reconnect usable during a
                // transient control-plane timeout; expired or revoked
                // authorization is still rejected by the privileged service.
                return await _vpnClient.ConnectAsync(
                    state.CachedAuthorization!.ToServiceAuthorization(),
                    state.Identity.PrivateKey,
                    antiLeakEnabled,
                    cancellationToken).ConfigureAwait(false);
            }
            if (profile.Unchanged &&
                (!cachedAuthorizationMatchesTarget ||
                 state.CachedProfileVersion != profile.Version))
            {
                profile = await _api.GetManagedVpnProfileAsync(
                    state.Session.AccessToken,
                    state.DeviceId,
                    state.LocationId,
                    state.RoutingMode,
                    state.BypassRegion,
                    null,
                    cancellationToken).ConfigureAwait(false);
            }
            if (profile.Revoked)
            {
                throw new NativeClientFlowException(
                    "vpn_profile_revoked");
            }

            if (profile.RotationRequired)
            {
                var identity = state.PendingIdentity ??
                    WireGuardIdentity.Generate(
                        checked(state.Identity.KeyEpoch + 1));
                if (state.PendingIdentity is null)
                {
                    state = state with
                    {
                        PendingIdentity = identity,
                    };
                    _stateStore.Save(state);
                }

                await _api.RotateManagedVpnKeyAsync(
                    state.Session.AccessToken,
                    state.DeviceId,
                    identity,
                    cancellationToken).ConfigureAwait(false);
                state = state with
                {
                    Identity = identity,
                    PendingIdentity = null,
                    CachedProfileVersion = null,
                    CachedAuthorization = null,
                };
                _stateStore.Save(state);
                profile = await _api.GetManagedVpnProfileAsync(
                    state.Session.AccessToken,
                    state.DeviceId,
                    state.LocationId,
                    state.RoutingMode,
                    state.BypassRegion,
                    null,
                    cancellationToken).ConfigureAwait(false);
                if (profile.Revoked || profile.RotationRequired)
                {
                    throw new NativeClientFlowException(
                        "vpn_key_rotation_failed");
                }
            }

            ManagedVpnProfileAuthorization authorization;
            if (profile.Unchanged)
            {
                if (state.CachedProfileVersion != profile.Version ||
                    state.CachedAuthorization is null)
                {
                    throw new NativeClientFlowException(
                        "vpn_profile_cache_missing");
                }

                authorization = state.CachedAuthorization;
            }
            else
            {
                authorization = profile.Authorization ??
                    throw new NativeClientFlowException(
                        "vpn_profile_unsigned");
                state = state with
                {
                    CachedProfileVersion = profile.Version,
                    CachedAuthorization = authorization,
                };
                _stateStore.Save(state);
            }
            var response = await _vpnClient.ConnectAsync(
                authorization.ToServiceAuthorization(),
                state.Identity.PrivateKey,
                antiLeakEnabled,
                cancellationToken).ConfigureAwait(false);
            if (response.Success)
            {
                try
                {
                    await _api.ReportVpnConnectAsync(
                        state.Session.AccessToken,
                        new VpnConnectionTelemetry(
                            state.DeviceId,
                            profile.Version,
                            "amneziawg",
                            "connect"),
                        cancellationToken).ConfigureAwait(false);
                }
                catch (Exception error) when (
                    error is HttpRequestException or VexApiException)
                {
                    // Telemetry never changes the already-confirmed tunnel state.
                }
            }
            return response;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task ReportCachedConnectAsync(NativeClientState state)
    {
        try
        {
            await _api.ReportVpnConnectAsync(
                state.Session.AccessToken,
                new VpnConnectionTelemetry(
                    state.DeviceId,
                    state.CachedProfileVersion,
                    "amneziawg",
                    "connect"),
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error) when (
            error is HttpRequestException or VexApiException)
        {
            // Telemetry never changes the already-confirmed tunnel state.
        }
    }

    private static bool CachedAuthorizationMatchesTarget(
        NativeClientState state)
    {
        try
        {
            var encoded = state.CachedAuthorization!.PayloadBase64
                .Replace('-', '+')
                .Replace('_', '/');
            encoded = encoded.PadRight(
                encoded.Length + ((4 - (encoded.Length % 4)) % 4),
                '=');
            using var payload = JsonDocument.Parse(
                Convert.FromBase64String(encoded));
            var root = payload.RootElement;
            return root.TryGetProperty(
                    "profile_version",
                    out var version) &&
                version.TryGetInt32(out var parsedVersion) &&
                parsedVersion == state.CachedProfileVersion &&
                MatchesPayloadString(
                    root,
                    "device_id",
                    state.DeviceId) &&
                MatchesPayloadString(
                    root,
                    "requested_location_id",
                    state.LocationId) &&
                MatchesPayloadString(
                    root,
                    "routing_mode",
                    state.RoutingMode) &&
                MatchesPayloadString(
                    root,
                    "bypass_region",
                    state.BypassRegion ?? string.Empty);
        }
        catch (Exception error) when (
            error is FormatException or JsonException)
        {
            return false;
        }
    }

    private static bool MatchesPayloadString(
        JsonElement payload,
        string propertyName,
        string expected) =>
        payload.TryGetProperty(propertyName, out var value) &&
        value.ValueKind == JsonValueKind.String &&
        string.Equals(
            value.GetString(),
            expected,
            StringComparison.Ordinal);

    public async Task<VpnServiceResponse> DisconnectAsync(
        string reason,
        CancellationToken cancellationToken)
    {
        reason = string.IsNullOrWhiteSpace(reason)
            ? "user"
            : reason.Trim();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            var response = await _vpnClient.DisconnectAsync(
                cancellationToken).ConfigureAwait(false);
            if (response.Success)
            {
                try
                {
                    await _api.ReportVpnDisconnectAsync(
                        state.Session.AccessToken,
                        new VpnConnectionTelemetry(
                            state.DeviceId,
                            state.CachedProfileVersion,
                            "amneziawg",
                            reason),
                        cancellationToken).ConfigureAwait(false);
                }
                catch (Exception error) when (
                    error is HttpRequestException or VexApiException)
                {
                    // Telemetry never changes the already-confirmed tunnel state.
                }
            }
            return response;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SignOutAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _vpnClient.DisconnectAsync(
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _stateStore.Clear();
            _gate.Release();
        }
    }

    public async Task<NativeAccountSnapshot> GetAccountSnapshotAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            var summaryTask = _api.GetBillingSummaryAsync(
                state.Session.AccessToken,
                cancellationToken);
            var entitlementTask = _api.GetBillingEntitlementAsync(
                state.Session.AccessToken,
                cancellationToken);
            var userTask = _api.GetCurrentUserAsync(
                state.Session.AccessToken,
                cancellationToken);
            var devicesTask = _api.GetDevicesAsync(
                state.Session.AccessToken,
                cancellationToken);
            var usageTask = _api.GetDeviceUsageAsync(
                state.Session.AccessToken,
                cancellationToken);
            var paymentsTask = _api.GetBillingPaymentsAsync(
                state.Session.AccessToken,
                24,
                cancellationToken);
            var summary = await summaryTask.ConfigureAwait(false);
            var entitlement = await entitlementTask.ConfigureAwait(false);
            var user = await userTask.ConfigureAwait(false);
            var devices = await devicesTask.ConfigureAwait(false);
            var usage = await usageTask.ConfigureAwait(false);
            var payments = await paymentsTask.ConfigureAwait(false);
            return new NativeAccountSnapshot(
                user.Email,
                state.LocationId,
                entitlement,
                summary,
                devices,
                usage,
                payments);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<CheckoutSession> StartCheckoutAsync(
        string planId,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            return await _api.CreateCheckoutSessionAsync(
                state.Session.AccessToken,
                planId,
                provider: null,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<BillingPortalSession> GetBillingPortalSessionAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            return await _api.GetBillingPortalSessionAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<NativeAccountSnapshot> CancelSubscriptionAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            var entitlement = await _api.CancelSubscriptionAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var summary = await _api.GetBillingSummaryAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var user = await _api.GetCurrentUserAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var devices = await _api.GetDevicesAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var usage = await _api.GetDeviceUsageAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var payments = await _api.GetBillingPaymentsAsync(
                state.Session.AccessToken,
                24,
                cancellationToken).ConfigureAwait(false);
            return new NativeAccountSnapshot(
                user.Email,
                state.LocationId,
                entitlement,
                summary,
                devices,
                usage,
                payments);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<NativeSupportSnapshot> GetSupportSnapshotAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            var tickets = await _api.GetSupportTicketsAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            return BuildSupportSnapshot(tickets);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<SupportTicket> SendSupportMessageAsync(
        string message,
        string? subject,
        CancellationToken cancellationToken)
    {
        message = message.Trim();
        if (message.Length == 0)
        {
            throw new ArgumentException(
                "Support message is required.",
                nameof(message));
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = _stateStore.Load() ??
                throw new NativeClientFlowException("sign_in_required");
            state = await RefreshIfNeededAsync(
                state,
                cancellationToken).ConfigureAwait(false);
            var tickets = await _api.GetSupportTicketsAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var active = FindActiveSupportTicket(tickets);
            var resolvedSubject = ResolveSupportSubject(
                active,
                subject,
                message);
            return await _api.CreateSupportTicketAsync(
                state.Session.AccessToken,
                resolvedSubject,
                message,
                "windows_native",
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<Uri> GetSupportWebSocketUriAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(
                RequireCurrentState(),
                cancellationToken).ConfigureAwait(false);
            return await _api.GetSupportWebSocketUriAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SubmitClientDiagnosticsAsync(
        ClientDiagnosticsReport report,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(report);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(
                RequireCurrentState(),
                cancellationToken).ConfigureAwait(false);
            var enriched = report with
            {
                DeviceId = string.IsNullOrWhiteSpace(report.DeviceId)
                    ? state.DeviceId
                    : report.DeviceId,
            };
            await _api.SubmitClientDiagnosticsAsync(
                state.Session.AccessToken,
                enriched,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<AppRemoteConfig> GetRemoteConfigAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        _api.GetRemoteConfigAsync(metadata, cancellationToken);

    public Task<AppUpdateCheckResult> CheckForAppUpdateAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        _api.CheckForAppUpdateAsync(metadata, cancellationToken);

    private async Task<NativeClientState> RefreshIfNeededAsync(
        NativeClientState state,
        CancellationToken cancellationToken)
    {
        if (state.Session.ExpiresAt is null ||
            state.Session.ExpiresAt > _utcNow() + RefreshWindow)
        {
            return state;
        }

        var session = await _api.RefreshSessionAsync(
            state.Session.AccessToken,
            cancellationToken).ConfigureAwait(false);
        var refreshed = state with { Session = session };
        _stateStore.Save(refreshed);
        return refreshed;
    }

    private async Task<NativeClientState> CompletePendingRotationAsync(
        NativeClientState state,
        CancellationToken cancellationToken)
    {
        if (state.PendingIdentity is null)
        {
            return state;
        }

        await _api.RotateManagedVpnKeyAsync(
            state.Session.AccessToken,
            state.DeviceId,
            state.PendingIdentity,
            cancellationToken).ConfigureAwait(false);
        var committed = state with
        {
            Identity = state.PendingIdentity,
            PendingIdentity = null,
            CachedProfileVersion = null,
            CachedAuthorization = null,
        };
        _stateStore.Save(committed);
        return committed;
    }

    private async Task<NativeClientState> ProvisionAuthenticatedSessionCoreAsync(
        VexAuthSession session,
        CancellationToken cancellationToken)
    {
        var locations = await _api.GetLocationsAsync(
            session.AccessToken,
            cancellationToken).ConfigureAwait(false);
        var existingState = _stateStore.Load();
        var existingDevice = _stateStore.LoadDevice();
        var preferredLocationId =
            existingState?.SelectionMode == "manual"
                ? existingState.LocationId
                : existingDevice?.LocationId;
        var location = locations.FirstOrDefault(candidate =>
                candidate.Id == preferredLocationId) ??
            locations.FirstOrDefault() ??
            throw new NativeClientFlowException(
                "vpn_location_unavailable");
        var identity = existingDevice?.Identity ??
            WireGuardIdentity.Generate();
        var installationId =
            _stateStore.GetOrCreateInstallationId();
        var device = await _api.RegisterNativeDeviceAsync(
            session.AccessToken,
            installationId,
            identity.PublicKey,
            identity.KeyEpoch,
            location.Id,
            _appVersion,
            cancellationToken).ConfigureAwait(false);
        var state = new NativeClientState(
            session,
            installationId,
            device.Id,
            location.Id,
            identity,
            SelectionMode:
                existingState?.SelectionMode == "manual" &&
                location.Id == existingState.LocationId
                    ? "manual"
                    : "auto",
            RoutingMode: existingState?.RoutingMode ?? "full",
            BypassRegion: existingState?.BypassRegion);
        _stateStore.Save(state);
        return state;
    }

    private NativeClientState RequireCurrentState()
    {
        var state = _stateStore.Load();
        if (state is not null)
        {
            return state;
        }

        throw new NativeClientFlowException(
            _stateStore.GetAccessState() == ClientStateAccessKind.Locked
                ? "windows_hello_required"
                : "sign_in_required");
    }

    private static void ValidateRoutingMode(string routingMode)
    {
        if (routingMode is not ("full" or "split"))
        {
            throw new ArgumentException(
                "Routing mode is invalid.",
                nameof(routingMode));
        }
    }

    private static string? NormalizeBypassRegion(
        string routingMode,
        string? bypassRegion)
    {
        if (routingMode == "full")
        {
            return null;
        }

        bypassRegion = string.IsNullOrWhiteSpace(bypassRegion)
            ? "ru"
            : bypassRegion.Trim().ToLowerInvariant();
        ValidatePreference(bypassRegion, nameof(bypassRegion));
        return bypassRegion;
    }

    private static void ValidatePreference(
        string value,
        string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > 128 ||
            value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '-' or '_' or '.')))
        {
            throw new ArgumentException(
                "VPN preference is invalid.",
                parameterName);
        }
    }

    private static NativeSupportSnapshot BuildSupportSnapshot(
        IReadOnlyList<SupportTicket> tickets) =>
        new(
            tickets,
            FindActiveSupportTicket(tickets));

    private static SupportTicket? FindActiveSupportTicket(
        IReadOnlyList<SupportTicket> tickets) =>
        tickets.FirstOrDefault(ticket =>
            !IsClosedSupportTicket(ticket.Status));

    private static string ResolveSupportSubject(
        SupportTicket? activeTicket,
        string? subject,
        string message)
    {
        if (activeTicket is not null)
        {
            return activeTicket.Subject;
        }

        subject = string.IsNullOrWhiteSpace(subject)
            ? BuildSupportSubject(message)
            : subject.Trim();
        if (subject.Length == 0)
        {
            throw new ArgumentException(
                "Support subject is required.",
                nameof(subject));
        }

        return subject;
    }

    private static string BuildSupportSubject(string message)
    {
        var firstLine = message
            .Split(
                ["\r\n", "\n"],
                StringSplitOptions.None)
            .FirstOrDefault(line => !string.IsNullOrWhiteSpace(line))
            ?.Trim();
        if (string.IsNullOrEmpty(firstLine))
        {
            return "Вопрос в поддержку";
        }

        return firstLine.Length > 46
            ? firstLine[..43] + "..."
            : firstLine;
    }

    private static bool IsClosedSupportTicket(string status)
    {
        status = status.Trim();
        return status.Equals(
                   "closed",
                   StringComparison.OrdinalIgnoreCase) ||
               status.Equals(
                   "resolved",
                   StringComparison.OrdinalIgnoreCase);
    }
}

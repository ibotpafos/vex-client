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
    string? BypassRegion = null,
    VexEntitlement? CachedEntitlement = null,
    DateTimeOffset? CachedEntitlementCheckedAt = null,
    DateTimeOffset? CachedEntitlementValidUntil = null,
    IReadOnlyList<CachedSignedCandidateGrant>? CachedCandidateGrants = null,
    DateTimeOffset? CachedCandidatePolicyExpiresAt = null,
    WarmedProfileGrant? WarmedProfile = null);

public sealed record NativeDeviceState(
    string InstallationId,
    string DeviceId,
    string LocationId,
    WireGuardIdentity Identity);

public sealed class NativeClientFlowException : Exception
{
    public NativeClientFlowException(string code)
        : base(code)
    {
        Code = code;
    }

    public string Code { get; }
}

public sealed partial class NativeClientCoordinator
{
    private static readonly TimeSpan RefreshWindow =
        TimeSpan.FromMinutes(5);

    private readonly INativeClientApi _api;
    private readonly IClientStateStore _stateStore;
    private readonly IVpnControlClient _vpnClient;
    private readonly string _appVersion;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly DynamicRouteEngine _dynamicRoutes;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly SemaphoreSlim _recoveryGate = new(1, 1);

    public NativeClientCoordinator(
        INativeClientApi api,
        IClientStateStore stateStore,
        IVpnControlClient vpnClient,
        string appVersion,
        Func<DateTimeOffset>? utcNow = null,
        DynamicRouteEngine? dynamicRoutes = null,
        Func<VpnSignedProfileVerifier?>? profileWarmupVerifier = null)
    {
        _api = api;
        _stateStore = stateStore;
        _vpnClient = vpnClient;
        _appVersion = appVersion;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
        _dynamicRoutes = dynamicRoutes ?? new DynamicRouteEngine();
        _profileWarmupVerifier = profileWarmupVerifier;
    }

    public NativeClientState? CurrentState => _stateStore.Load();

    public event EventHandler? SessionChanged;

    public event EventHandler? ProfileScopeChanged;

    public ClientStateAccessKind CurrentStateAccess =>
        _stateStore.GetAccessState();

    public async Task<NativeClientState> ForceRefreshSessionAsync(
        CancellationToken cancellationToken,
        string? expectedAccessToken = null)
    {
        if (expectedAccessToken is null) CancelProfileWarmup();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = RequireCurrentState();
            if (expectedAccessToken is not null && state.Session.AccessToken != expectedAccessToken)
                throw new NativeClientFlowException("session_changed");
            if (expectedAccessToken is not null) CancelProfileWarmup();
            var session = await _api.RefreshSessionAsync(
                state.Session.AccessToken,
                cancellationToken).ConfigureAwait(false);
            var refreshed = state with { Session = session };
            cancellationToken.ThrowIfCancellationRequested();
            _stateStore.Save(refreshed);
            SessionChanged?.Invoke(this, EventArgs.Empty);
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
            return await WithSessionRetryCoreAsync(state =>
                _api.GetLocationsAsync(state.Session.AccessToken, cancellationToken),
                cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task SelectLocationAsync(
        string locationId,
        bool reconnectIfConnected,
        CancellationToken cancellationToken,
        bool antiLeakEnabled = true)
    {
        CancelProfileWarmup();
        ValidatePreference(locationId, nameof(locationId));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(RequireCurrentState(), cancellationToken)
                .ConfigureAwait(false);
            var locations = await _api.GetLocationsAsync(state.Session.AccessToken, cancellationToken)
                .ConfigureAwait(false);
            if (!locations.Any(location => string.Equals(location.Id, locationId, StringComparison.Ordinal)))
            {
                throw new NativeClientFlowException("vpn_location_unavailable");
            }
            var status = reconnectIfConnected
                ? await _vpnClient.GetStatusAsync(cancellationToken).ConfigureAwait(false)
                : null;
            if (status?.Snapshot.Phase != VpnConnectionPhase.Connected)
            {
                _stateStore.Save(state with
                {
                    LocationId = locationId,
                    SelectionMode = "manual",
                    CachedProfileVersion = null,
                    CachedAuthorization = null,
                    CachedCandidatePolicyExpiresAt = null,
                    CachedCandidateGrants = null,
                    WarmedProfile = null,
                });
                return;
            }
            try
            {
                // The privileged service validates the complete replacement
                // before it replaces the existing working tunnel.
                var response = await ConnectWithRecoveryCoreAsync(locationId, state.RoutingMode,
                    antiLeakEnabled, false, cancellationToken, false).ConfigureAwait(false);
                if (!response.Success)
                {
                    throw new NativeClientFlowException(response.ErrorCode ?? "vpn_server_switch_failed");
                }
            }
            catch
            {
                // Session rejection must never resurrect an expired session.
                if (_stateStore.Load() is not { } latest) { throw; }
                _stateStore.Save(state with
                {
                    Session = latest.Session,
                    CachedEntitlement = latest.CachedEntitlement ?? state.CachedEntitlement,
                    CachedEntitlementCheckedAt = latest.CachedEntitlementCheckedAt,
                    CachedEntitlementValidUntil = latest.CachedEntitlementValidUntil,
                });
                if (state.CachedAuthorization is not null)
                {
                    // Restoring the previous signed grant is safe even when
                    // the replacement failed after admission. Cancellation
                    // belongs to the caller and never triggers a new tunnel.
                    if (!cancellationToken.IsCancellationRequested)
                    {
                        await _vpnClient.ConnectAsync(state.CachedAuthorization.ToServiceAuthorization(),
                            state.Identity.PrivateKey, antiLeakEnabled, cancellationToken).ConfigureAwait(false);
                    }
                }
                throw;
            }
        }
        finally
        {
            _gate.Release();
            ProfileScopeChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task SetRoutingPreferencesAsync(
        string routingMode,
        string? bypassRegion,
        CancellationToken cancellationToken)
    {
        CancelProfileWarmup();
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
                CachedCandidatePolicyExpiresAt = null,
                CachedCandidateGrants = null,
                WarmedProfile = null,
            });
        }
        finally
        {
            _gate.Release();
            ProfileScopeChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task<NativeClientState> SignInAndProvisionAsync(
        string email,
        string password,
        CancellationToken cancellationToken)
    {
        CancelProfileWarmup();
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
        CancelProfileWarmup();
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
        CancellationToken cancellationToken) =>
        (await ConnectAuthorizedAsync(locationId, routingMode, antiLeakEnabled,
            false, cancellationToken).ConfigureAwait(false)).Response;

    private async Task<ConnectionAttempt> ConnectAuthorizedAsync(
        string? locationId,
        string routingMode,
        bool antiLeakEnabled,
        bool forceRefresh,
        CancellationToken cancellationToken)
    {
        CancelProfileWarmup();
        ValidateRoutingMode(routingMode);
        if (locationId is not null)
        {
            ValidatePreference(locationId, nameof(locationId));
        }
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await ConnectAttemptCoreWithSessionRetryAsync(locationId, routingMode,
                antiLeakEnabled, forceRefresh, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private sealed record ConnectionAttempt(
        VpnServiceResponse Response,
        NativeClientState State,
        ManagedVpnProfileAuthorization Authorization);

    private async Task<ConnectionAttempt> ConnectAttemptCoreWithSessionRetryAsync(
        string? locationId, string routingMode, bool antiLeakEnabled, bool forceRefresh,
        CancellationToken cancellationToken, ResilienceConnectionCandidate? candidate = null,
        ResiliencePolicy? selectionPolicy = null, bool deferExpiredGrantRefresh = false)
    {
        try
        {
            return await ConnectCoreAsync(locationId, routingMode, antiLeakEnabled,
                forceRefresh, cancellationToken, candidate, selectionPolicy, deferExpiredGrantRefresh).ConfigureAwait(false);
        }
        catch (VexApiException error) when (error.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            await RefreshRejectedSessionAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await ConnectCoreAsync(locationId, routingMode, antiLeakEnabled,
                    true, cancellationToken, candidate, selectionPolicy, deferExpiredGrantRefresh).ConfigureAwait(false);
            }
            catch (VexApiException retryError) when (retryError.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                _stateStore.Clear();
                SessionChanged?.Invoke(this, EventArgs.Empty);
                throw new NativeClientFlowException("sign_in_required");
            }
        }
    }

    private async Task<ConnectionAttempt> ConnectCoreAsync(
        string? locationId,
        string routingMode,
        bool antiLeakEnabled,
        bool forceRefresh,
        CancellationToken cancellationToken,
        ResilienceConnectionCandidate? candidate = null,
        ResiliencePolicy? selectionPolicy = null, bool deferExpiredGrantRefresh = false)
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
                CachedCandidateGrants = null,
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
                CachedCandidateGrants = null,
            };
        }

        state = await EnsureEntitlementAsync(state, cancellationToken)
            .ConfigureAwait(false);

        if (!forceRefresh && candidate is null)
            state = PromoteWarmedProfile(state);

        if (!forceRefresh && candidate is null)
        {
            state = await PreferPolicyGrantAsync(state, selectionPolicy, cancellationToken).ConfigureAwait(false);
        }

        if (!forceRefresh && candidate is null && state.PendingIdentity is null &&
            state.CachedProfileVersion is > 0 &&
            state.CachedAuthorization is not null &&
            CachedAuthorizationMatchesTarget(state) && CachedAuthorityUnexpired(state))
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
                return new(cachedResponse, state, state.CachedAuthorization!);
            }

            if (deferExpiredGrantRefresh || !string.Equals(
                    cachedResponse.ErrorCode,
                    "profile_expired",
                    StringComparison.Ordinal))
            {
                return new(cachedResponse, state, state.CachedAuthorization!);
            }

            state = state with
            {
                CachedProfileVersion = null,
                CachedAuthorization = null,
                CachedCandidatePolicyExpiresAt = null,
                CachedCandidateGrants = null,
            };
        }

        var cachedAuthorizationMatchesTarget =
            !forceRefresh && candidate is null && state.CachedAuthorization is not null &&
            state.CachedProfileVersion is > 0 &&
            CachedAuthorizationMatchesTarget(state) && CachedAuthorityUnexpired(state);
        ManagedVpnProfile profile;
        try
        {
            profile = await GetProfileAsync(state,
                cachedAuthorizationMatchesTarget ? state.CachedProfileVersion : null,
                candidate, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (
            candidate is null && !cancellationToken.IsCancellationRequested &&
            cachedAuthorizationMatchesTarget &&
            error is HttpRequestException or IOException or TaskCanceledException)
        {
            var cachedResponse = await _vpnClient.ConnectAsync(
                state.CachedAuthorization!.ToServiceAuthorization(), state.Identity.PrivateKey,
                antiLeakEnabled, cancellationToken).ConfigureAwait(false);
            return new(cachedResponse, state, state.CachedAuthorization);
        }
        if (profile.Unchanged && (candidate is not null || !cachedAuthorizationMatchesTarget ||
            state.CachedProfileVersion != profile.Version))
        {
            profile = await GetProfileAsync(state, null, candidate, cancellationToken).ConfigureAwait(false);
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
                CachedCandidatePolicyExpiresAt = null,
                CachedCandidateGrants = null,
            };
            _stateStore.Save(state);
            profile = await GetProfileAsync(state, null, candidate, cancellationToken).ConfigureAwait(false);
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
            if (state.CachedAuthorization is { } previous && !SameGrantTransport(previous, authorization))
            {
                state = state with { CachedCandidateGrants = null };
                if (_stateStore.Load() is { } persisted)
                {
                    // Keep the working authorization; a changed signed
                    // transport invalidates only speculative route leases.
                    _stateStore.Save(persisted with { CachedCandidateGrants = null });
                }
            }
            state = state with
            {
                CachedProfileVersion = profile.Version,
                CachedAuthorization = authorization,
                CachedCandidatePolicyExpiresAt = CandidatePolicyExpiry(state, candidate),
            };
        }
        if (candidate is null)
        {
            state = await PreferPolicyGrantAsync(state, selectionPolicy, cancellationToken).ConfigureAwait(false);
            authorization = state.CachedAuthorization ?? authorization;
        }
        if (candidate is not null && !GrantMatchesCandidate(authorization, state, candidate))
        {
            throw new NativeClientFlowException("vpn_candidate_grant_mismatch");
        }
        var response = await _vpnClient.ConnectAsync(
            authorization.ToServiceAuthorization(),
            state.Identity.PrivateKey,
            antiLeakEnabled,
            cancellationToken).ConfigureAwait(false);
        if (response.Success)
        {
            _stateStore.Save(state);
            try
            {
                await _api.ReportVpnConnectAsync(
                    state.Session.AccessToken,
                    new VpnConnectionTelemetry(
                        state.DeviceId,
                        state.CachedProfileVersion ?? profile.Version,
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
        return new(response, state, authorization);
    }

    private Task<ManagedVpnProfile> GetProfileAsync(NativeClientState state, int? knownVersion,
        ResilienceConnectionCandidate? candidate, CancellationToken cancellationToken)
    {
        if (candidate is not null && FindCachedCandidateGrant(state, candidate) is { } cached)
        {
            return Task.FromResult(new ManagedVpnProfile(cached.ProfileVersion, state.DeviceId,
                false, false, cached.Authorization));
        }
        return candidate is null
            ? _api.GetManagedVpnProfileAsync(state.Session.AccessToken, state.DeviceId, state.LocationId,
                state.RoutingMode, state.BypassRegion, knownVersion, cancellationToken)
            : RequestCandidateGrantAsync(state, candidate, cancellationToken);
    }

    private async Task<ManagedVpnProfile> RequestCandidateGrantAsync(NativeClientState state,
        ResilienceConnectionCandidate candidate, CancellationToken cancellationToken)
    {
        using var routeCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        routeCancellation.CancelAfter(TimeSpan.FromSeconds(8));
        return await _api.GetManagedVpnCandidateProfileAsync(state.Session.AccessToken, state.DeviceId, state.LocationId,
            state.RoutingMode, state.BypassRegion, candidate.Id, routeCancellation.Token).ConfigureAwait(false);
    }

    public async Task<ResiliencePolicy?> GetResiliencePolicyAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await GetResiliencePolicyCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private async Task<ResiliencePolicy?> GetResiliencePolicyCoreAsync(CancellationToken cancellationToken)
    {
        var state = await RefreshIfNeededAsync(RequireCurrentState(), cancellationToken)
            .ConfigureAwait(false);
        try
        {
            var policy = await _api.GetResiliencePolicyAsync(
                state.Session.AccessToken, cancellationToken).ConfigureAwait(false);
            if (policy?.Probe is not null && policy.Candidates is not null)
            {
                _dynamicRoutes.CachePolicy(policy);
            }
            return policy?.Probe is not null && policy.Candidates is not null
                ? policy : _dynamicRoutes.CachedPolicy(_utcNow());
        }
        catch (Exception error) when (
            !cancellationToken.IsCancellationRequested &&
            error is HttpRequestException or IOException or TaskCanceledException)
        {
            return _dynamicRoutes.CachedPolicy(_utcNow());
        }
    }

    public async Task<IReadOnlyList<VpnDeviceUsage>> GetDeviceUsageAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await RefreshIfNeededAsync(RequireCurrentState(), cancellationToken)
                .ConfigureAwait(false);
            return await _api.GetDeviceUsageAsync(state.Session.AccessToken, cancellationToken)
                .ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task InvalidateCachedEntitlementAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_stateStore.Load() is { } state)
            {
                _stateStore.Save(state with
                {
                    CachedEntitlementCheckedAt = null,
                    CachedEntitlementValidUntil = null,
                });
            }
        }
        finally { _gate.Release(); }
    }

    public async Task ValidateEntitlementAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WithSessionRetryCoreAsync(async state =>
            {
                await EnsureEntitlementAsync(state, cancellationToken).ConfigureAwait(false);
                return true;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task InvalidateProfileAsync(CancellationToken cancellationToken)
    {
        CancelProfileWarmup();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_stateStore.Load() is { } state)
            {
                _stateStore.Save(state with { CachedProfileVersion = null, CachedAuthorization = null,
                    CachedCandidateGrants = null, WarmedProfile = null });
            }
        }
        finally
        {
            _gate.Release();
            ProfileScopeChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public Task<VpnServiceResponse> GetTunnelStatusAsync(CancellationToken cancellationToken) =>
        _vpnClient.GetStatusAsync(cancellationToken);

    public Task<VpnServiceResponse> DisconnectTunnelAsync(CancellationToken cancellationToken) =>
        _vpnClient.DisconnectAsync(cancellationToken);

    private async Task<NativeClientState> EnsureEntitlementAsync(
        NativeClientState state, CancellationToken cancellationToken)
    {
        var now = _utcNow();
        if (state.CachedEntitlement?.HasPaidAccess == true &&
            (KnownEntitlementExpiry(state.CachedEntitlement) is not { } knownExpiry || knownExpiry > now) &&
            state.CachedEntitlementValidUntil > now &&
            state.CachedEntitlementCheckedAt > now - TimeSpan.FromMinutes(5))
        {
            return state;
        }
        try
        {
            var entitlement = await _api.GetBillingEntitlementAsync(
                state.Session.AccessToken, cancellationToken).ConfigureAwait(false);
            state = CacheEntitlement(state, entitlement);
            _stateStore.Save(state);
            if (!entitlement.HasPaidAccess || state.CachedEntitlementValidUntil <= now)
            {
                throw new NativeClientFlowException("vpn_entitlement_required");
            }
            return state;
        }
        catch (Exception error) when (
            !cancellationToken.IsCancellationRequested &&
            error is HttpRequestException or IOException or TaskCanceledException)
        {
            if (KnownEntitlementExpiry(state.CachedEntitlement) is { } paidExpiry && paidExpiry <= now)
            {
                throw new NativeClientFlowException("vpn_entitlement_required");
            }
            if (state.CachedEntitlement?.HasPaidAccess == true &&
                state.CachedEntitlementValidUntil > now)
            {
                return state;
            }
            throw;
        }
    }

    private NativeClientState CacheEntitlement(NativeClientState state, VexEntitlement entitlement)
    {
        var now = _utcNow();
        var validUntil = entitlement.HasPaidAccess ? now.AddHours(24) : now;
        if (KnownEntitlementExpiry(entitlement) is { } expiresAt && expiresAt < validUntil)
        {
            validUntil = expiresAt;
        }
        return state with
        {
            CachedEntitlement = entitlement,
            CachedEntitlementCheckedAt = now,
            CachedEntitlementValidUntil = validUntil,
        };
    }

    private static DateTimeOffset? KnownEntitlementExpiry(VexEntitlement? entitlement)
    {
        if (entitlement is null) { return null; }
        // Effective expiry accounts for the authoritative subscription state;
        // the billing period is the compatible fallback when it is absent.
        var value = !string.IsNullOrWhiteSpace(entitlement.EffectiveExpiresAt)
            ? entitlement.EffectiveExpiresAt : entitlement.CurrentPeriodEnd;
        return DateTimeOffset.TryParse(value, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var expiresAt) ? expiresAt : null;
    }

    private async Task RefreshRejectedSessionAsync(CancellationToken cancellationToken)
    {
        var state = RequireCurrentState();
        try
        {
            var session = await _api.RefreshSessionAsync(state.Session.AccessToken, cancellationToken)
                .ConfigureAwait(false);
            _stateStore.Save(state with { Session = session });
            SessionChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (VexApiException error) when (error.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            _stateStore.Clear();
            SessionChanged?.Invoke(this, EventArgs.Empty);
            throw new NativeClientFlowException("sign_in_required");
        }
    }

    private async Task<T> WithSessionRetryCoreAsync<T>(
        Func<NativeClientState, Task<T>> operation, CancellationToken cancellationToken)
    {
        var state = await RefreshIfNeededAsync(RequireCurrentState(), cancellationToken).ConfigureAwait(false);
        try { return await operation(state).ConfigureAwait(false); }
        catch (VexApiException error) when (error.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            await RefreshRejectedSessionAsync(cancellationToken).ConfigureAwait(false);
            try { return await operation(RequireCurrentState()).ConfigureAwait(false); }
            catch (VexApiException retryError) when (retryError.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                _stateStore.Clear();
                SessionChanged?.Invoke(this, EventArgs.Empty);
                throw new NativeClientFlowException("sign_in_required");
            }
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
        CancellationToken cancellationToken,
        string? expectedAccessToken = null,
        Action? onMatchedSignOut = null)
    {
        if (expectedAccessToken is null) CancelProfileWarmup();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var matched = false;
        try
        {
            if (expectedAccessToken is not null && _stateStore.Load()?.Session.AccessToken != expectedAccessToken)
                return;
            matched = true;
            if (expectedAccessToken is not null) CancelProfileWarmup();
            onMatchedSignOut?.Invoke();
            await _vpnClient.DisconnectAsync(
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                if (matched)
                {
                    _stateStore.Clear();
                    SessionChanged?.Invoke(this, EventArgs.Empty);
                }
            }
            finally { _gate.Release(); }
        }
    }

    public async Task<NativeAccountSnapshot> GetAccountSnapshotAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await WithSessionRetryCoreAsync(state =>
                LoadAccountSnapshotCoreAsync(state, cancellationToken), cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
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
            state = CacheEntitlement(state, entitlement);
            _stateStore.Save(state);
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
            _stateStore.Save(CacheEntitlement(state, entitlement));
            return new NativeAccountSnapshot(
                user.Email,
                state.LocationId,
                entitlement,
                summary,
                devices,
                usage,
                payments) { UserId = user.Id };
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

        await RefreshRejectedSessionAsync(cancellationToken).ConfigureAwait(false);
        return RequireCurrentState();
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
            CachedCandidatePolicyExpiresAt = null,
            CachedCandidateGrants = null,
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
        cancellationToken.ThrowIfCancellationRequested();
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
        cancellationToken.ThrowIfCancellationRequested();
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

}

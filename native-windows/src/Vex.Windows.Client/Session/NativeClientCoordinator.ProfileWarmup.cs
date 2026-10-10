using System.Security.Cryptography;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Session;

public sealed record WarmedProfileGrant(string UserId, string DeviceId, string LocationId,
    string RoutingMode, string? BypassRegion, string ClientPublicKey, int ClientKeyEpoch,
    int ProfileVersion, ManagedVpnProfileAuthorization Authorization, DateTimeOffset ExpiresAt);

public sealed partial class NativeClientCoordinator
{
    private readonly Func<VpnSignedProfileVerifier?>? _profileWarmupVerifier;
    private readonly object _warmupSync = new();
    private CancellationTokenSource? _warmupCancellation;
    private long _warmupGeneration;

    public void CancelProfileWarmup()
    {
        CancellationTokenSource? cancellation;
        lock (_warmupSync)
        {
            _warmupGeneration++;
            cancellation = _warmupCancellation;
            _warmupCancellation = null;
        }
        CancelWarmup(cancellation);
    }

    public async Task<bool> WarmProfileAsync(string? locationId, string routingMode,
        string? bypassRegion, CancellationToken cancellationToken)
    {
        CancelProfileWarmup();
        ValidateRoutingMode(routingMode);
        bypassRegion = NormalizeBypassRegion(routingMode, bypassRegion);
        long capturedGeneration;
        lock (_warmupSync) capturedGeneration = _warmupGeneration;
        if (_profileWarmupVerifier is null || !_gate.Wait(0)) return false;
        NativeClientState? captured;
        try { captured = _stateStore.Load(); }
        finally { _gate.Release(); }
        if (captured is null || captured.PendingIdentity is not null ||
            captured.Session.ExpiresAt <= _utcNow() + RefreshWindow ||
            (locationId is not null && locationId != captured.LocationId)) return false;
        locationId = captured.LocationId;
        var target = captured with { RoutingMode = routingMode, BypassRegion = bypassRegion };
        if (MatchingWarmedProfile(target) is { ExpiresAt: var expires } && expires > _utcNow() + RefreshWindow)
            return false;
        if (captured.RoutingMode == routingMode && captured.BypassRegion == bypassRegion &&
            captured.CachedAuthorization is not null && CachedAuthorizationMatchesTarget(captured) &&
            TryReadGrantMetadata(captured.CachedAuthorization, out var cached) &&
            cached.ExpiresAt > _utcNow() + RefreshWindow) return false;

        using var warmup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        warmup.CancelAfter(TimeSpan.FromSeconds(40));
        CancellationTokenSource? previous;
        long generation;
        lock (_warmupSync)
        {
            if (capturedGeneration != _warmupGeneration) return false;
            generation = ++_warmupGeneration;
            previous = _warmupCancellation;
            _warmupCancellation = warmup;
        }
        CancelWarmup(previous);
        try
        {
            var verifier = _profileWarmupVerifier();
            if (verifier is null) return false;
            var entitlementState = captured;
            if (!HasBoundedOfflineEntitlement(captured) || captured.CachedEntitlementCheckedAt <= _utcNow() - RefreshWindow)
            {
                var entitlement = await _api.GetBillingEntitlementAsync(captured.Session.AccessToken, warmup.Token).ConfigureAwait(false);
                entitlementState = CacheEntitlement(captured, entitlement);
                if (!HasBoundedOfflineEntitlement(entitlementState))
                {
                    await PersistWarmEntitlementAsync(captured, entitlementState, generation, warmup.Token).ConfigureAwait(false);
                    return false;
                }
            }
            var profile = await _api.GetManagedVpnProfileAsync(captured.Session.AccessToken,
                captured.DeviceId, locationId, routingMode, bypassRegion, null, warmup.Token).ConfigureAwait(false);
            warmup.Token.ThrowIfCancellationRequested();
            if (profile.Revoked || profile.RotationRequired || profile.Unchanged || profile.Version < 1 ||
                profile.DeviceId != captured.DeviceId || profile.Authorization is null ||
                profile.ClientPublicKey != captured.Identity.PublicKey || profile.ClientKeyEpoch != captured.Identity.KeyEpoch)
                return false;
            var authorized = verifier.Authorize(profile.Authorization.ToServiceAuthorization(), captured.Identity.PrivateKey);
            if (authorized.ExpiresAt <= _utcNow() + TimeSpan.FromSeconds(30) ||
                authorized.LocationId != locationId || !SignedWarmupScopeMatches(profile.Authorization, target, profile.Version))
                return false;
            var grant = new WarmedProfileGrant(captured.Session.User.Id, captured.DeviceId, locationId,
                routingMode, bypassRegion, captured.Identity.PublicKey, captured.Identity.KeyEpoch,
                profile.Version, profile.Authorization, authorized.ExpiresAt);
            if (!_gate.Wait(0)) return false;
            try
            {
                var latest = _stateStore.Load();
                lock (_warmupSync)
                {
                    if (warmup.IsCancellationRequested || generation != _warmupGeneration || latest is null ||
                        !SameWarmupSnapshot(captured, latest)) return false;
                    // Only the optional cache changes. Working authorization,
                    // routing preference and assigned location remain intact.
                    var saved = MergeNewerEntitlement(latest, entitlementState) with { WarmedProfile = grant };
                    _stateStore.Save(saved);
                    return true;
                }
            }
            finally { _gate.Release(); }
        }
        catch (Exception error) when (error is VexApiException or NativeClientFlowException or HttpRequestException or
            IOException or UnauthorizedAccessException or CryptographicException or JsonException or
            VpnTunnelException or InvalidOperationException or ArgumentException or OperationCanceledException)
        {
            return false;
        }
        finally
        {
            lock (_warmupSync)
                if (ReferenceEquals(_warmupCancellation, warmup)) _warmupCancellation = null;
        }
    }

    private async Task PersistWarmEntitlementAsync(NativeClientState captured, NativeClientState observed,
        long generation, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var latest = _stateStore.Load();
            lock (_warmupSync)
            {
                if (cancellationToken.IsCancellationRequested || generation != _warmupGeneration ||
                    latest is null || !SameWarmupSnapshot(captured, latest)) return;
                var saved = MergeNewerEntitlement(latest, observed);
                if (!ReferenceEquals(saved, latest)) _stateStore.Save(saved);
            }
        }
        finally { _gate.Release(); }
    }

    private static NativeClientState MergeNewerEntitlement(NativeClientState latest, NativeClientState observed) =>
        observed.CachedEntitlementCheckedAt is { } checkedAt &&
        (latest.CachedEntitlementCheckedAt is not { } latestChecked || latestChecked < checkedAt)
            ? latest with { CachedEntitlement = observed.CachedEntitlement, CachedEntitlementCheckedAt = checkedAt,
                CachedEntitlementValidUntil = observed.CachedEntitlementValidUntil }
            : latest;

    public bool TryGetCachedReconnectLocation(string routingMode, string? bypassRegion, out string locationId)
    {
        locationId = string.Empty;
        try
        {
            ValidateRoutingMode(routingMode);
            bypassRegion = NormalizeBypassRegion(routingMode, bypassRegion);
            if (_stateStore.GetAccessState() != ClientStateAccessKind.Available || _stateStore.Load() is not { } state ||
                state.PendingIdentity is not null || !HasBoundedOfflineEntitlement(state)) return false;
            var target = state with { RoutingMode = routingMode, BypassRegion = bypassRegion };
            var grant = MatchingWarmedProfile(target);
            if (grant is not null && _profileWarmupVerifier?.Invoke() is { } verifier &&
                verifier.Authorize(grant.Authorization.ToServiceAuthorization(), state.Identity.PrivateKey).ExpiresAt == grant.ExpiresAt)
            {
                locationId = state.LocationId;
                return true;
            }
            if (state.RoutingMode != routingMode || state.BypassRegion != bypassRegion ||
                state.CachedAuthorization is null || state.CachedProfileVersion is not > 0 ||
                !CachedAuthorizationMatchesTarget(state) || !TryReadGrantMetadata(state.CachedAuthorization, out var metadata) ||
                metadata.UserId != state.Session.User.Id || metadata.ExpiresAt is null) return false;
            if (!CachedAuthorityUnexpired(state) && !EligibleRoutes(state, state.CachedAuthorization,
                    _dynamicRoutes.CachedPolicy(_utcNow())).Any(candidate => FindCachedCandidateGrant(state, candidate) is not null))
                return false;
            locationId = state.LocationId;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or
            JsonException or VpnTunnelException or InvalidOperationException or ArgumentException) { return false; }
    }

    private bool HasBoundedOfflineEntitlement(NativeClientState state) =>
        state.CachedEntitlement?.HasPaidAccess == true && state.CachedEntitlementValidUntil > _utcNow() &&
        state.CachedEntitlementCheckedAt is { } checkedAt && checkedAt <= _utcNow() &&
        state.CachedEntitlementValidUntil <= checkedAt.AddHours(24) &&
        (KnownEntitlementExpiry(state.CachedEntitlement) is not { } expiry || expiry > _utcNow());

    private NativeClientState PromoteWarmedProfile(NativeClientState state)
    {
        if (state.CachedAuthorization is not null && CachedAuthorizationMatchesTarget(state) && CachedAuthorityUnexpired(state))
            return state;
        var grant = MatchingWarmedProfile(state);
        if (grant is null) return state;
        try
        {
            var verifier = _profileWarmupVerifier?.Invoke();
            if (verifier is null || verifier.Authorize(grant.Authorization.ToServiceAuthorization(),
                    state.Identity.PrivateKey).ExpiresAt != grant.ExpiresAt) return state;
            return state with { CachedProfileVersion = grant.ProfileVersion, CachedAuthorization = grant.Authorization,
                CachedCandidatePolicyExpiresAt = null, CachedCandidateGrants = null, WarmedProfile = null };
        }
        catch (Exception error) when (error is VpnTunnelException or InvalidOperationException or ArgumentException or
            IOException or UnauthorizedAccessException or CryptographicException) { return state; }
    }

    private WarmedProfileGrant? MatchingWarmedProfile(NativeClientState state) =>
        state.PendingIdentity is null && state.WarmedProfile is { } grant && grant.Authorization is not null &&
        grant.UserId == state.Session.User.Id && grant.DeviceId == state.DeviceId && grant.LocationId == state.LocationId &&
        grant.RoutingMode == state.RoutingMode && grant.BypassRegion == state.BypassRegion &&
        grant.ClientPublicKey == state.Identity.PublicKey && grant.ClientKeyEpoch == state.Identity.KeyEpoch &&
        grant.ExpiresAt > _utcNow() && grant.ProfileVersion > 0 &&
        SignedWarmupScopeMatches(grant.Authorization, state, grant.ProfileVersion) ? grant : null;

    private static bool SameWarmupSnapshot(NativeClientState before, NativeClientState after) =>
        before.Session.AccessToken == after.Session.AccessToken && before.Session.User.Id == after.Session.User.Id &&
        before.InstallationId == after.InstallationId && before.DeviceId == after.DeviceId && before.LocationId == after.LocationId &&
        before.RoutingMode == after.RoutingMode && before.BypassRegion == after.BypassRegion &&
        before.Identity == after.Identity && after.PendingIdentity is null &&
        before.CachedProfileVersion == after.CachedProfileVersion && before.CachedAuthorization == after.CachedAuthorization;

    private static bool SignedWarmupScopeMatches(ManagedVpnProfileAuthorization authorization,
        NativeClientState state, int version)
    {
        if (!TryReadGrantMetadata(authorization, out var metadata) || metadata.UserId != state.Session.User.Id ||
            metadata.DeviceId != state.DeviceId || metadata.LocationId != state.LocationId ||
            metadata.RoutingMode != state.RoutingMode || metadata.BypassRegion != (state.BypassRegion ?? string.Empty) ||
            metadata.ProfileVersion != version) return false;
        try
        {
            var encoded = authorization.PayloadBase64.Replace('-', '+').Replace('_', '/');
            encoded = encoded.PadRight(encoded.Length + ((4 - encoded.Length % 4) % 4), '=');
            using var payload = JsonDocument.Parse(Convert.FromBase64String(encoded));
            return MatchesPayloadString(payload.RootElement, "requested_location_id", state.LocationId);
        }
        catch (Exception error) when (error is FormatException or JsonException) { return false; }
    }

    private static void CancelWarmup(CancellationTokenSource? cancellation)
    {
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
    }
}

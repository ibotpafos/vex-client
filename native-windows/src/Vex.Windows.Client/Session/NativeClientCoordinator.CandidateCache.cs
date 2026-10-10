using Vex.Windows.Client.Api;
using System.Text.Json;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    public bool CanReconnectFromCachedAuthorization
    {
        get
        {
            if (CurrentState is not { CachedAuthorization: not null, CachedProfileVersion: > 0,
                PendingIdentity: null } state || !CachedAuthorizationMatchesTarget(state) ||
                !TryReadGrantMetadata(state.CachedAuthorization, out var metadata) ||
                metadata.UserId != state.Session.User.Id || metadata.ExpiresAt is null) { return false; }
            return CachedAuthorityUnexpired(state) ||
                EligibleRoutes(state, state.CachedAuthorization, _dynamicRoutes.CachedPolicy(_utcNow()))
                    .Any(candidate => FindCachedCandidateGrant(state, candidate) is not null);
        }
    }

    private bool CachedAuthorityUnexpired(NativeClientState state)
    {
        if (state.CachedAuthorization is null || state.CachedCandidatePolicyExpiresAt <= _utcNow()) { return false; }
        return !TryReadGrantMetadata(state.CachedAuthorization, out var metadata) ||
            (metadata.UserId == state.Session.User.Id &&
             (metadata.ExpiresAt is null || metadata.ExpiresAt > _utcNow()));
    }

    private DateTimeOffset? CandidatePolicyExpiry(NativeClientState state, ResilienceConnectionCandidate? candidate)
    {
        if (candidate is null) { return null; }
        var cached = FindCachedCandidateGrant(state, candidate);
        if (cached is not null) { return cached.PolicyExpiresAt; }
        return DateTimeOffset.TryParse(_dynamicRoutes.CachedPolicy(_utcNow())?.ExpiresAt,
            out var expiry) ? expiry : null;
    }

    private async Task<NativeClientState> PreferPolicyGrantAsync(NativeClientState state,
        ResiliencePolicy? policy, CancellationToken cancellationToken)
    {
        if (state.CachedAuthorization is not { } original || !PolicyUnexpired(policy)) { return state; }
        var routes = EligibleRoutes(state, original, policy);
        var preferred = (!CachedAuthorityUnexpired(state)
            ? routes.FirstOrDefault(candidate => FindCachedCandidateGrant(state, candidate) is not null) : null)
            ?? routes.FirstOrDefault();
        if (preferred is null || (CachedAuthorityUnexpired(state) && GrantMatchesCandidate(original, state, preferred)))
        {
            return state;
        }
        using var routeCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        routeCancellation.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            var profile = await GetProfileAsync(state, null, preferred, routeCancellation.Token).ConfigureAwait(false);
            if (profile.Authorization is null || profile.Revoked || profile.RotationRequired || profile.Unchanged ||
                !GrantMatchesCandidate(profile.Authorization, state, preferred) || !PolicyUnexpired(policy))
            {
                return state;
            }
            return state with
            {
                CachedProfileVersion = profile.Version,
                CachedAuthorization = profile.Authorization,
                CachedCandidatePolicyExpiresAt = CandidatePolicyExpiry(state, preferred),
            };
        }
        catch (VexApiException error) when (error.StatusCode == System.Net.HttpStatusCode.NotFound ||
            error.Code == "vpn_profile_candidate_rejected") { return state; }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
            error is HttpRequestException or IOException or TaskCanceledException) { return state; }
    }

    private CachedSignedCandidateGrant? FindCachedCandidateGrant(
        NativeClientState state, ResilienceConnectionCandidate candidate) =>
        state.CachedCandidateGrants?.Take(3).FirstOrDefault(grant =>
            grant is not null && grant.Authorization is not null &&
            grant.CandidateId == candidate.Id && grant.NodeId == candidate.NodeId &&
            string.Equals(grant.Endpoint, candidate.Endpoint, StringComparison.OrdinalIgnoreCase) &&
            CandidateGrantScopeMatches(grant, state) &&
            state.CachedAuthorization is { } current && SameGrantTransport(current, grant.Authorization) &&
            grant.ExpiresAt > _utcNow() && grant.PolicyExpiresAt > _utcNow() &&
            GrantMatchesCandidate(grant.Authorization, state, candidate) &&
            TryReadGrantMetadata(grant.Authorization, out var metadata) &&
            metadata.ProfileVersion == grant.ProfileVersion && metadata.ExpiresAt > _utcNow());

    private static bool CandidateGrantScopeMatches(CachedSignedCandidateGrant grant, NativeClientState state) =>
        grant.UserId == state.Session.User.Id && grant.DeviceId == state.DeviceId &&
        grant.LocationId == state.LocationId && grant.RoutingMode == state.RoutingMode &&
        (grant.BypassRegion ?? string.Empty) == (state.BypassRegion ?? string.Empty) &&
        grant.ClientPublicKey == state.Identity.PublicKey && grant.ClientKeyEpoch == state.Identity.KeyEpoch;

    private async Task PrefetchCandidateGrantsAsync(ConnectionAttempt attempt, ResiliencePolicy? policy,
        CancellationToken cancellationToken)
    {
        if (!attempt.Response.Success || !PolicyUnexpired(policy) ||
            !TryReadGrantMetadata(attempt.Authorization, out var primary) || primary.ExpiresAt <= _utcNow() ||
            primary.ExpiresAt is null) { return; }
        var routes = EligibleRoutes(attempt, policy).Take(3).ToArray();
        if (routes.Length == 0 || policy is null) { return; }
        using var prefetchCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        prefetchCancellation.CancelAfter(TimeSpan.FromSeconds(8));
        var token = prefetchCancellation.Token;
        var grants = new List<CachedSignedCandidateGrant>(3);
        foreach (var candidate in routes)
        {
            if (token.IsCancellationRequested || !PolicyUnexpired(policy)) { break; }
            var state = RequireCurrentState();
            try
            {
                ManagedVpnProfileAuthorization? authorization;
                int profileVersion;
                if (GrantMatchesCandidate(attempt.Authorization, state, candidate))
                {
                    authorization = attempt.Authorization;
                    profileVersion = state.CachedProfileVersion ?? 0;
                }
                else if (FindCachedCandidateGrant(state, candidate) is { } cached)
                {
                    authorization = cached.Authorization;
                    profileVersion = cached.ProfileVersion;
                }
                else
                {
                    var profile = await _api.GetManagedVpnCandidateProfileAsync(state.Session.AccessToken,
                        state.DeviceId, state.LocationId, state.RoutingMode, state.BypassRegion,
                        candidate.Id, token).ConfigureAwait(false);
                    if (profile.Revoked || profile.RotationRequired || profile.Unchanged) { continue; }
                    authorization = profile.Authorization;
                    profileVersion = profile.Version;
                }
                if (authorization is null || profileVersion < 1 ||
                    !GrantMatchesCandidate(authorization, state, candidate) ||
                    !SameGrantTransport(attempt.Authorization, authorization) ||
                    !TryReadGrantMetadata(authorization, out var metadata) ||
                    metadata.ProfileVersion != profileVersion || metadata.ExpiresAt is not { } grantExpiry ||
                    !DateTimeOffset.TryParse(policy.ExpiresAt, out var policyExpiry) ||
                    !DateTimeOffset.TryParse(candidate.ExpiresAt, out var candidateExpiry)) { continue; }
                var expiry = grantExpiry < candidateExpiry ? grantExpiry : candidateExpiry;
                if (expiry <= _utcNow() || policyExpiry <= _utcNow()) { continue; }
                grants.Add(new(candidate.Id, candidate.NodeId, candidate.Endpoint, state.Session.User.Id,
                    state.DeviceId, state.LocationId, state.RoutingMode, state.BypassRegion,
                    state.Identity.PublicKey, state.Identity.KeyEpoch, profileVersion, authorization, expiry, policyExpiry));
            }
            catch (Exception error) when (error is VexApiException or HttpRequestException or IOException or
                TaskCanceledException or OperationCanceledException)
            {
                // Prefetch is bounded and advisory; a working admitted tunnel
                // and its protected authorization survive API outages.
                if (error is HttpRequestException or IOException or OperationCanceledException) { break; }
            }
        }
        if (grants.Count == 0) { return; }
        try
        {
            var state = RequireCurrentState();
            var retained = (state.CachedCandidateGrants ?? []).Take(3).Where(grant => grant is not null &&
                policy.Candidates.Any(candidate => candidate is not null && candidate.Id == grant.CandidateId &&
                    FindCachedCandidateGrant(state, candidate) is not null));
            var orderedIds = routes.Select(candidate => candidate.Id).ToArray();
            // Failed or partial prefetch cannot erase an admitted, unexpired
            // lease merely because its path is temporarily quarantined.
            var merged = grants.Concat(retained).GroupBy(grant => grant.CandidateId, StringComparer.Ordinal)
                .Select(group => group.First())
                .OrderBy(grant => Array.IndexOf(orderedIds, grant.CandidateId) is var index && index >= 0 ? index : int.MaxValue)
                .ThenBy(grant => grant.CandidateId, StringComparer.Ordinal)
                .Take(3).ToArray();
            _stateStore.Save(state with { CachedCandidateGrants = merged });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException)
        {
            // Failure to persist optional leases does not undo admission.
        }
    }

    private static bool SameGrantTransport(ManagedVpnProfileAuthorization left, ManagedVpnProfileAuthorization right)
    {
        static JsonDocument Read(ManagedVpnProfileAuthorization authorization)
        {
            var encoded = authorization.PayloadBase64.Replace('-', '+').Replace('_', '/');
            if (encoded.Length > 90_000) { throw new FormatException(); }
            encoded = encoded.PadRight(encoded.Length + ((4 - encoded.Length % 4) % 4), '=');
            return JsonDocument.Parse(Convert.FromBase64String(encoded));
        }
        try
        {
            using var leftDocument = Read(left);
            using var rightDocument = Read(right);
            var leftTunnel = leftDocument.RootElement.GetProperty("tunnel");
            var rightTunnel = rightDocument.RootElement.GetProperty("tunnel");
            var leftFields = leftTunnel.EnumerateObject().Where(field => field.Name != "endpoint").ToArray();
            var rightFields = rightTunnel.EnumerateObject().Where(field => field.Name != "endpoint").ToArray();
            return leftFields.Length == rightFields.Length && leftFields.All(field =>
                rightTunnel.TryGetProperty(field.Name, out var value) && JsonElement.DeepEquals(field.Value, value));
        }
        catch (Exception error) when (error is JsonException or FormatException or KeyNotFoundException or InvalidOperationException)
        {
            return false;
        }
    }
}

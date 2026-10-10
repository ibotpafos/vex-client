using System.Net;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    public async Task<VpnServiceResponse> ConnectWithRecoveryAsync(
        string? locationId,
        string routingMode,
        bool antiLeakEnabled,
        bool allowsAutomaticFailover,
        CancellationToken cancellationToken,
        bool forceFreshProfile = false)
    {
        ValidateRoutingMode(routingMode);
        if (locationId is not null) { ValidatePreference(locationId, nameof(locationId)); }
        await _recoveryGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await ConnectWithRecoveryCoreAsync(locationId, routingMode, antiLeakEnabled,
                    allowsAutomaticFailover, cancellationToken, forceFreshProfile).ConfigureAwait(false);
            }
            finally { _gate.Release(); }
        }
        finally { _recoveryGate.Release(); }
    }

    private async Task<VpnServiceResponse> ConnectWithRecoveryCoreAsync(
        string? locationId, string routingMode, bool antiLeakEnabled, bool allowsAutomaticFailover,
        CancellationToken cancellationToken, bool forceFreshProfile)
    {
        ResiliencePolicy? policy = null;
        try { policy = await GetResiliencePolicyCoreAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
            error is VexApiException or HttpRequestException or IOException or TaskCanceledException)
        {
            policy = _dynamicRoutes.CachedPolicy(_utcNow());
        }
        var attempt = await ConnectAttemptCoreWithSessionRetryAsync(locationId, routingMode,
            antiLeakEnabled, forceFreshProfile, cancellationToken, selectionPolicy: policy, deferExpiredGrantRefresh: true).ConfigureAwait(false);
        var initialLocation = attempt.State.LocationId;
        RecordAdmittedRouteOutcome(attempt, policy);
        if (attempt.Response.Success || !IsRecoverableConnectError(attempt.Response.ErrorCode))
        {
            await PrefetchCandidateGrantsAsync(attempt, policy, cancellationToken).ConfigureAwait(false);
            return attempt.Response;
        }

        // Advisory identifiers never change privileged configuration. Each
        // changed endpoint needs a server-resolved grant signed by the pinned key.
        var routes = EligibleRoutes(attempt, policy);
        var triedEndpoints = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (TryReadGrantMetadata(attempt.Authorization, out var metadata))
        {
            triedEndpoints.Add(metadata.Endpoint);
        }
        var routeBudget = Math.Clamp(policy?.Probe.MaxCandidates ?? 1, 1, 3);
        var candidateAttempts = 1;
        foreach (var candidate in routes)
        {
            if (candidateAttempts >= routeBudget || !PolicyUnexpired(policy)) { break; }
            if (!triedEndpoints.Add(candidate.Endpoint)) { continue; }
            candidateAttempts++;
            try
            {
                attempt = await ConnectAttemptCoreWithSessionRetryAsync(initialLocation, routingMode,
                    antiLeakEnabled, true, cancellationToken, candidate, deferExpiredGrantRefresh: true).ConfigureAwait(false);
            }
            catch (VexApiException error) when (error.StatusCode == HttpStatusCode.NotFound ||
                error.Code == "vpn_profile_candidate_rejected")
            {
                // Stale policy and servers without this additive contract
                // cannot authorize this path. Keep supported recovery available.
                continue;
            }
            catch (NativeClientFlowException error) when (error.Code == "vpn_candidate_grant_mismatch")
            {
                // Older servers can ignore the query; never execute their
                // direct grant as though it authorized the requested relay.
                continue;
            }
            catch (Exception error) when (!cancellationToken.IsCancellationRequested &&
                error is HttpRequestException or IOException or TaskCanceledException)
            {
                // A new path needs an online grant. Cached admitted grants
                // remain usable only while the service accepts their expiry.
                break;
            }
            RecordAdmittedRouteOutcome(attempt, policy);
            if (attempt.Response.Success || !IsRecoverableConnectError(attempt.Response.ErrorCode))
            {
                await PrefetchCandidateGrantsAsync(attempt, policy, cancellationToken).ConfigureAwait(false);
                return attempt.Response;
            }
        }

        if (!forceFreshProfile)
        {
            attempt = await ConnectAttemptCoreWithSessionRetryAsync(initialLocation, routingMode,
                antiLeakEnabled, true, cancellationToken, deferExpiredGrantRefresh: true).ConfigureAwait(false);
            RecordAdmittedRouteOutcome(attempt, policy);
        }
        if (attempt.Response.Success || !allowsAutomaticFailover ||
            !VpnAutopilotAssessment.Assess(attempt.Response.ErrorCode, attempt.Response.Diagnostics).CanFailover)
        {
            await PrefetchCandidateGrantsAsync(attempt, policy, cancellationToken).ConfigureAwait(false);
            return attempt.Response;
        }
        var locations = await WithSessionRetryCoreAsync(current =>
            _api.GetLocationsAsync(current.Session.AccessToken, cancellationToken), cancellationToken).ConfigureAwait(false);
        var alternate = VpnLocationSelector.SelectAutomaticLocation(
            locations.Where(candidate => !string.Equals(candidate.Id, initialLocation,
                StringComparison.OrdinalIgnoreCase)).ToArray(), null);
        if (alternate is null) { return attempt.Response; }
        attempt = await ConnectAttemptCoreWithSessionRetryAsync(alternate, routingMode,
            antiLeakEnabled, true, cancellationToken, deferExpiredGrantRefresh: true).ConfigureAwait(false);
        RecordAdmittedRouteOutcome(attempt, policy);
        await PrefetchCandidateGrantsAsync(attempt, policy, cancellationToken).ConfigureAwait(false);
        return attempt.Response;
    }

    private static bool IsRecoverableConnectError(string? code) => code is
        "tunnel_no_handshake" or "no_handshake" or "tunnel_handshake_timeout" or
        "tunnel_network_degraded" or "tunnel_start_failed" or "tunnel_runtime_failure" or
        "tunnel_adapter_timeout" or "profile_expired";

    private bool PolicyUnexpired(ResiliencePolicy? policy) => policy is not null &&
        DateTimeOffset.TryParse(policy.ExpiresAt, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var expiresAt) && expiresAt > _utcNow();

    private IReadOnlyList<ResilienceConnectionCandidate> EligibleRoutes(ConnectionAttempt attempt, ResiliencePolicy? policy)
        => EligibleRoutes(attempt.State, attempt.Authorization, policy);

    private IReadOnlyList<ResilienceConnectionCandidate> EligibleRoutes(NativeClientState state,
        ManagedVpnProfileAuthorization authorization, ResiliencePolicy? policy)
    {
        if (policy is null || !TryReadGrantMetadata(authorization, out var metadata) ||
            metadata.UserId != state.Session.User.Id ||
            !string.Equals(metadata.DeviceId, state.DeviceId, StringComparison.Ordinal) ||
            !string.Equals(metadata.LocationId, state.LocationId, StringComparison.OrdinalIgnoreCase))
        {
            return [];
        }
        // The exact granted endpoint anchors the advisory exit-node scope.
        var grantedRoute = policy.Candidates.FirstOrDefault(candidate => candidate is not null &&
            candidate.DeviceId == metadata.DeviceId &&
            string.Equals(candidate.LocationId, metadata.LocationId, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(candidate.Endpoint, metadata.Endpoint, StringComparison.OrdinalIgnoreCase));
        return grantedRoute is null ? [] : _dynamicRoutes.OrderedCandidates(metadata.DeviceId,
            metadata.LocationId, grantedRoute.NodeId, metadata.Protocol, metadata.HasHeaderKey, policy, _utcNow());
    }

    private void RecordAdmittedRouteOutcome(ConnectionAttempt attempt, ResiliencePolicy? policy)
    {
        if (policy is null || !TryReadGrantMetadata(attempt.Authorization, out var metadata)) { return; }
        var candidate = EligibleRoutes(attempt, policy)
            .FirstOrDefault(route => string.Equals(route.Endpoint, metadata.Endpoint, StringComparison.OrdinalIgnoreCase));
        if (candidate is null) { return; }
        // Keep the attempted grant explicit even when a failed fresh profile
        // leaves the previous working authorization in protected storage.
        try
        {
            if (attempt.Response.Success) { _dynamicRoutes.RecordSuccess(candidate, policy, _utcNow()); }
            else if (IsRecoverableConnectError(attempt.Response.ErrorCode))
            {
                _dynamicRoutes.RecordFailure(candidate, policy, _utcNow());
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException)
        {
            // Route history is advisory; its persistence cannot change an
            // admission outcome already confirmed by the service.
        }
    }

    private sealed record GrantMetadata(string UserId, string DeviceId, string LocationId, string RoutingMode,
        string BypassRegion, int ProfileVersion, string Protocol, string Endpoint,
        bool HasHeaderKey, DateTimeOffset? ExpiresAt);

    private static bool TryReadGrantMetadata(ManagedVpnProfileAuthorization authorization, out GrantMetadata metadata)
    {
        metadata = null!;
        try
        {
            var encoded = authorization.PayloadBase64.Replace('-', '+').Replace('_', '/');
            if (encoded.Length > 90_000) { return false; }
            encoded = encoded.PadRight(encoded.Length + ((4 - encoded.Length % 4) % 4), '=');
            using var document = JsonDocument.Parse(Convert.FromBase64String(encoded));
            var root = document.RootElement;
            var tunnel = root.GetProperty("tunnel");
            var hasHeaderKey = tunnel.TryGetProperty("amnezia", out var amnezia) &&
                amnezia.ValueKind == JsonValueKind.Object &&
                amnezia.TryGetProperty("header_protection_key", out var headerKey) &&
                headerKey.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(headerKey.GetString());
            metadata = new(root.TryGetProperty("user_id", out var user) ? user.GetString() ?? string.Empty : string.Empty,
                root.GetProperty("device_id").GetString() ?? string.Empty,
                root.GetProperty("assigned_location_id").GetString() ?? string.Empty,
                root.GetProperty("routing_mode").GetString() ?? string.Empty,
                root.TryGetProperty("bypass_region", out var bypass) ? bypass.GetString() ?? string.Empty : string.Empty,
                root.GetProperty("profile_version").GetInt32(),
                tunnel.GetProperty("protocol").GetString() ?? string.Empty,
                tunnel.GetProperty("endpoint").GetString() ?? string.Empty, hasHeaderKey,
                root.TryGetProperty("expires_at", out var expires) && expires.ValueKind == JsonValueKind.String &&
                    DateTimeOffset.TryParse(expires.GetString(), out var expiry) ? expiry : null);
            return metadata.Endpoint.Length > 0;
        }
        catch (Exception error) when (error is JsonException or FormatException or KeyNotFoundException or InvalidOperationException)
        {
            return false;
        }
    }

    private static bool GrantMatchesCandidate(ManagedVpnProfileAuthorization authorization, NativeClientState state,
        ResilienceConnectionCandidate candidate) => TryReadGrantMetadata(authorization, out var metadata) &&
        metadata.UserId == state.Session.User.Id &&
        metadata.DeviceId == state.DeviceId && metadata.DeviceId == candidate.DeviceId &&
        string.Equals(metadata.LocationId, state.LocationId, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(metadata.LocationId, candidate.LocationId, StringComparison.OrdinalIgnoreCase) &&
        metadata.RoutingMode == state.RoutingMode && metadata.BypassRegion == (state.BypassRegion ?? string.Empty) &&
        metadata.ProfileVersion > 0 && metadata.Protocol == "amneziawg" && metadata.HasHeaderKey &&
        string.Equals(metadata.Endpoint, candidate.Endpoint, StringComparison.OrdinalIgnoreCase);
}

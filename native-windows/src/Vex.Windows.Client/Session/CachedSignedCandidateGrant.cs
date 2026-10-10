using Vex.Windows.Client.Api;

namespace Vex.Windows.Client.Session;

/// <summary>A server-signed path lease scoped to one protected local identity.</summary>
public sealed record CachedSignedCandidateGrant(
    string CandidateId,
    string NodeId,
    string Endpoint,
    string UserId,
    string DeviceId,
    string LocationId,
    string RoutingMode,
    string? BypassRegion,
    string ClientPublicKey,
    int ClientKeyEpoch,
    int ProfileVersion,
    ManagedVpnProfileAuthorization Authorization,
    DateTimeOffset ExpiresAt,
    DateTimeOffset PolicyExpiresAt)
{
    public override string ToString() =>
        $"{nameof(CachedSignedCandidateGrant)} {{ CandidateId = {CandidateId}, " +
        $"DeviceId = {DeviceId}, Authorization = <redacted> }}";
}

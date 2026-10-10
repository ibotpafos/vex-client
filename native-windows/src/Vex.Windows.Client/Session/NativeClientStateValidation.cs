using Vex.Windows.Client.Api;

namespace Vex.Windows.Client.Session;

public static class NativeClientStateValidation
{
    public static bool IsValidSession(VexAuthSession? session) => session?.User is { } user &&
        !string.IsNullOrWhiteSpace(user.Id) && !string.IsNullOrWhiteSpace(user.Email) &&
        !string.IsNullOrWhiteSpace(user.Status) && !string.IsNullOrWhiteSpace(session.AccessToken);

    public static bool IsValid(NativeClientState? state) => state is not null &&
        IsValidSession(state.Session) && !string.IsNullOrWhiteSpace(state.InstallationId) &&
        state.LocationId is not null && state.Identity is { KeyEpoch: > 0 } &&
        !string.IsNullOrWhiteSpace(state.Identity.PrivateKey) && !string.IsNullOrWhiteSpace(state.Identity.PublicKey) &&
        (state.VpnProvisioningPending
            ? state.DeviceId == string.Empty && state.PendingIdentity is null &&
                state.CachedProfileVersion is null && state.CachedAuthorization is null &&
                state.CachedCandidateGrants is null && state.CachedCandidatePolicyExpiresAt is null &&
                state.WarmedProfile is null
            : !string.IsNullOrWhiteSpace(state.DeviceId) && !string.IsNullOrWhiteSpace(state.LocationId));
}

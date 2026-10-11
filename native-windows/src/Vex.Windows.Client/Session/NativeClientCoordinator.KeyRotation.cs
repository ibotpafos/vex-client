using System.Net;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    private sealed record ProfileClientIdentity(string PublicKey, int Epoch);

    private static ProfileClientIdentity? ReadProfileClientIdentity(NativeClientState state, ManagedVpnProfile profile)
    {
        if (profile.DeviceId != state.DeviceId || profile.Version < 1)
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        if (profile.Revoked) throw new NativeClientFlowException("vpn_profile_revoked");
        // Older managed-profile servers omit both identity fields. They still
        // use the existing idempotent rotation contract, without epoch inference.
        if (profile.ClientPublicKey is null && profile.ClientKeyEpoch is null) return null;
        if (string.IsNullOrWhiteSpace(profile.ClientPublicKey) || profile.ClientKeyEpoch is not > 0)
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        return new(profile.ClientPublicKey, profile.ClientKeyEpoch.Value);
    }

    private static NativeClientState AlignProfileIdentity(NativeClientState state, ManagedVpnProfile profile)
    {
        var observed = ReadProfileClientIdentity(state, profile);
        if (observed is null) return state;
        if (observed.PublicKey != state.Identity.PublicKey || observed.Epoch < state.Identity.KeyEpoch)
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        return observed.Epoch == state.Identity.KeyEpoch ? state :
            ClearIdentityCaches(state with { Identity = state.Identity with { KeyEpoch = observed.Epoch } });
    }

    private static NativeClientState ClearIdentityCaches(NativeClientState state) => state with
    {
        CachedProfileVersion = null, CachedAuthorization = null,
        CachedCandidatePolicyExpiresAt = null, CachedCandidateGrants = null, WarmedProfile = null,
    };

    private static int NextIdentityEpoch(int epoch)
    {
        if (epoch < 1 || epoch == int.MaxValue)
            throw new NativeClientFlowException("vpn_key_rotation_failed");
        return epoch + 1;
    }

    private void PersistProfileEpoch(NativeClientState before, NativeClientState aligned,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var saved = ValidateCurrentIdentity(before);
        if (before.Identity == aligned.Identity) return;
        // Epoch alignment is independent of a tentative location/routing switch.
        _stateStore.Save(ClearIdentityCaches(saved with { Identity = aligned.Identity }));
    }

    private async Task<NativeClientState> CompletePendingRotationAsync(NativeClientState state,
        CancellationToken cancellationToken, ManagedVpnProfile? observedProfile = null)
    {
        if (state.PendingIdentity is not { } pending) return state;
        var intent = Volatile.Read(ref _accountIntent);
        if (pending.KeyEpoch < 1)
            throw new NativeClientFlowException("vpn_key_rotation_failed");
        var profile = observedProfile ?? await GetProfileAsync(state, null, null, cancellationToken)
            .WaitAsync(cancellationToken).ConfigureAwait(false);
        EnsureAccountIntent(intent, cancellationToken);
        var observed = ReadProfileClientIdentity(state, profile);
        if (observed is not null)
        {
            if (observed.Epoch < state.Identity.KeyEpoch)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            if (observed.PublicKey == pending.PublicKey && observed.Epoch >= pending.KeyEpoch)
                return CommitPendingIdentity(state, pending with { KeyEpoch = observed.Epoch }, cancellationToken);
            if (observed.PublicKey != state.Identity.PublicKey || observed.Epoch < state.Identity.KeyEpoch)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            var nextEpoch = NextIdentityEpoch(observed.Epoch);
            if (nextEpoch < pending.KeyEpoch)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            // A PSK-only server rotation advances the same epoch counter. Keep
            // the pending private key when rebasing an unaccepted attempt.
            if (pending.KeyEpoch != nextEpoch)
            {
                pending = pending with { KeyEpoch = nextEpoch };
                ValidateCurrentIdentity(state);
                state = state with { PendingIdentity = pending };
                cancellationToken.ThrowIfCancellationRequested();
                _stateStore.Save(state);
            }
        }

        var rotated = await _api.RotateManagedVpnKeyAsync(state.Session.AccessToken, state.DeviceId,
            pending, cancellationToken).WaitAsync(cancellationToken).ConfigureAwait(false);
        // Idempotency replay returns the current device, not the historical
        // rotation result. Never commit a key solely because POST returned 200.
        ValidateAcknowledgement(rotated, state.Session, pending, state.DeviceId, allowEpochAdvance: true);
        // The exact device/public-key acknowledgement confirms acceptance of
        // this private key. Retain it before another request can fail or cancel.
        state = CommitPendingIdentity(state, pending, CancellationToken.None);
        EnsureAccountIntent(intent, cancellationToken);
        profile = await GetProfileAsync(state, null, null, cancellationToken)
            .WaitAsync(cancellationToken).ConfigureAwait(false);
        EnsureAccountIntent(intent, cancellationToken);
        observed = ReadProfileClientIdentity(state, profile);
        if (observed is not null && (observed.PublicKey != pending.PublicKey || observed.Epoch < pending.KeyEpoch))
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        var aligned = AlignProfileIdentity(state, profile);
        PersistProfileEpoch(state, aligned, cancellationToken);
        return aligned;
    }

    private NativeClientState CommitPendingIdentity(NativeClientState state, WireGuardIdentity pending,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateCurrentIdentity(state);
        var committed = ClearIdentityCaches(state with { Identity = pending, PendingIdentity = null });
        _stateStore.Save(committed);
        return committed;
    }

    private NativeClientState ValidateCurrentIdentity(NativeClientState state)
    {
        var saved = RequireCurrentState();
        if (saved.Session.User.Id != state.Session.User.Id || saved.Session.AccessToken != state.Session.AccessToken ||
            saved.InstallationId != state.InstallationId || saved.DeviceId != state.DeviceId ||
            saved.VpnRegistrationId != state.VpnRegistrationId || saved.VpnExternalDeviceId != state.VpnExternalDeviceId ||
            saved.Identity != state.Identity || saved.PendingIdentity != state.PendingIdentity)
            throw new NativeClientFlowException("session_changed");
        return saved;
    }
}

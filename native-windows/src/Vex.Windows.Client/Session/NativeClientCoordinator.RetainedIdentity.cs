using System.Net;
using Vex.Windows.Client.Api;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    private async Task<NativeDeviceState?> RecoverRetainedDeviceIdentityAsync(
        VexAuthSession session, NativeClientState? previous, string installationId, string locationId,
        CancellationToken cancellationToken)
    {
        var capturedDevice = _stateStore.LoadDevice();
        var retained = await OwnedDeviceAsync(session, previous, installationId, cancellationToken)
            .ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        EnsureRetainedRecoveryContext(previous, capturedDevice, installationId);
        if (retained is null) return null;
        if (retained.Identity is not { KeyEpoch: > 0 } original ||
            string.IsNullOrWhiteSpace(original.PrivateKey) || string.IsNullOrWhiteSpace(original.PublicKey) ||
            string.IsNullOrWhiteSpace(retained.LocationId))
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        var pending = retained.PendingIdentity;
        if (pending is not null && (pending.KeyEpoch < 1 || string.IsNullOrWhiteSpace(pending.PrivateKey) ||
            string.IsNullOrWhiteSpace(pending.PublicKey) || pending.PublicKey == original.PublicKey))
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");

        // Registration replay uses the client's epoch before looking up the
        // installation binding. Resolve PSK-only advances and lost rotation
        // acknowledgements against this owned device before sending that POST.
        var profile = await _api.GetManagedVpnProfileAsync(session.AccessToken,
            retained.DeviceId, locationId, "full", null, null, cancellationToken)
            .WaitAsync(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        EnsureRetainedRecoveryContext(previous, capturedDevice, installationId);
        var context = new NativeClientState(session, installationId, retained.DeviceId,
            retained.LocationId, original, pending);
        var observed = ReadProfileClientIdentity(context, profile);
        if (observed is null)
        {
            if (pending is not null)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            return retained;
        }

        NativeDeviceState recovered;
        if (pending is not null && observed.PublicKey == pending.PublicKey && observed.Epoch >= pending.KeyEpoch)
        {
            recovered = retained with
            {
                Identity = pending with { KeyEpoch = observed.Epoch },
                PendingIdentity = null,
                UserId = session.User.Id,
            };
        }
        else
        {
            if (observed.PublicKey != original.PublicKey || observed.Epoch < original.KeyEpoch)
                throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
            if (pending is not null)
            {
                var nextEpoch = NextIdentityEpoch(observed.Epoch);
                if (nextEpoch < pending.KeyEpoch)
                    throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
                pending = pending with { KeyEpoch = nextEpoch };
            }
            recovered = retained with
            {
                Identity = original with { KeyEpoch = observed.Epoch },
                PendingIdentity = pending,
                UserId = session.User.Id,
            };
        }

        cancellationToken.ThrowIfCancellationRequested();
        EnsureRetainedRecoveryContext(previous, capturedDevice, installationId);
        if (recovered != retained) _stateStore.SaveDevice(recovered);
        cancellationToken.ThrowIfCancellationRequested();
        EnsureRetainedRecoveryContext(previous, recovered, installationId);
        return recovered;
    }

    private void EnsureRetainedRecoveryContext(NativeClientState? previous,
        NativeDeviceState? capturedDevice, string installationId)
    {
        var current = _stateStore.Load();
        if (previous is null ? current is not null : current is null ||
            current.Session.User.Id != previous.Session.User.Id ||
            current.Session.AccessToken != previous.Session.AccessToken ||
            current.InstallationId != previous.InstallationId || current.DeviceId != previous.DeviceId ||
            current.Identity != previous.Identity || current.PendingIdentity != previous.PendingIdentity ||
            current.VpnProvisioningPending != previous.VpnProvisioningPending ||
            current.LocationId != previous.LocationId || current.RoutingMode != previous.RoutingMode ||
            current.BypassRegion != previous.BypassRegion)
            throw new NativeClientFlowException("session_changed");
        if (_stateStore.GetOrCreateInstallationId() != installationId ||
            _stateStore.LoadDevice() != capturedDevice)
            throw new NativeClientFlowException("session_changed");
    }
}

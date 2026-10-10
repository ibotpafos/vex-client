using System.Net;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Session;

public sealed partial class NativeClientCoordinator
{
    private void EnsureAccountIntent(long intent, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (intent != Volatile.Read(ref _accountIntent)) throw new NativeClientFlowException("session_changed");
    }

    private async Task<VpnServiceResponse> ConnectAccountFencedAsync(long intent,
        VpnProfileAuthorization authorization, string privateKey, bool antiLeakEnabled,
        CancellationToken cancellationToken)
    {
        EnsureAccountIntent(intent, cancellationToken);
        _nativeRetirementRequired = true;
        if (_stateStore.Load() is { } starting)
            _stateStore.Save(starting with { NativeRetirementRequired = true });
        VpnServiceResponse response;
        try
        {
            response = await _vpnClient.ConnectAsync(authorization, privateKey, antiLeakEnabled,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or System.Net.Sockets.SocketException)
        {
            // Closing a caller's pipe does not cancel a command already admitted
            // by the service. Send retirement before releasing the account gate.
            await RetireNativeConnectAsync().ConfigureAwait(false);
            throw;
        }
        if (intent != Volatile.Read(ref _accountIntent) || cancellationToken.IsCancellationRequested)
        {
            // The coordinator gate still excludes the new account's commands.
            // Retire a late old-account activation before accepting that login.
            await RetireNativeConnectAsync().ConfigureAwait(false);
        }
        EnsureAccountIntent(intent, cancellationToken);
        _nativeRetirementRequired = false;
        if (_stateStore.Load() is { } completed)
            _stateStore.Save(completed with { NativeRetirementRequired = false });
        return response;
    }

    private async Task PrepareAuthenticatedAccountAsync(VexAuthSession session, long intent,
        CancellationToken cancellationToken)
    {
        EnsureAccountIntent(intent, cancellationToken);
        if (!NativeClientStateValidation.IsValidSession(session))
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
        var previous = _stateStore.Load();
        if (_nativeRetirementRequired || previous?.NativeRetirementRequired == true ||
            previous is null && _stateStore.HasStoredSession)
            await RetireNativeConnectAsync().ConfigureAwait(false);
        else if (previous is { VpnProvisioningPending: false } && previous.Session.User.Id != session.User.Id)
        {
            var status = await _vpnClient.GetStatusAsync(cancellationToken).WaitAsync(cancellationToken)
                .ConfigureAwait(false);
            EnsureAccountIntent(intent, cancellationToken);
            if (!status.Success || status.Snapshot.Phase != VpnConnectionPhase.Disconnected)
                await RetireNativeConnectAsync().ConfigureAwait(false);
        }
        EnsureAccountIntent(intent, cancellationToken);
    }

    private async Task ClearRejectedSessionAsync()
    {
        var previous = _stateStore.Load();
        if (_nativeRetirementRequired || previous?.NativeRetirementRequired == true ||
            previous is null && _stateStore.HasStoredSession)
            await RetireNativeConnectAsync().ConfigureAwait(false);
        else if (previous is { VpnProvisioningPending: false })
        {
            var status = await _vpnClient.GetStatusAsync(CancellationToken.None).ConfigureAwait(false);
            if (!status.Success || status.Snapshot.Phase != VpnConnectionPhase.Disconnected)
                await RetireNativeConnectAsync().ConfigureAwait(false);
        }
        _stateStore.Clear();
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task RetireNativeConnectAsync()
    {
        _nativeRetirementRequired = true;
        if (_stateStore.Load() is { } retiring)
            _stateStore.Save(retiring with { NativeRetirementRequired = true });
        var stopped = await _vpnClient.DisconnectAsync(CancellationToken.None).ConfigureAwait(false);
        if (!stopped.Success || stopped.Snapshot.Phase != VpnConnectionPhase.Disconnected)
            throw new NativeClientFlowException("vpn_disconnect_required");
        if (_stateStore.Load() is { } state)
            _stateStore.Save(state with { NativeRetirementRequired = false });
        _nativeRetirementRequired = false;
    }

    private static bool LegacyExternalMatches(string? external, string globalId,
        IReadOnlyList<VpnLocation> locations) => external == globalId ||
        locations.Any(location => external == globalId + ":" + location.Id);

    private static bool OwnedLegacy(VpnDevice device, VexAuthSession session) =>
        !string.IsNullOrWhiteSpace(device.Id) && device.Status == "active" &&
        device.ProvisioningMode == "managed_native" && device.ClientKeyOwnership == "client" &&
        device.Platform == "windows" && (device.UserId is null || device.UserId == session.User.Id) &&
        !string.IsNullOrWhiteSpace(device.PublicKey);

    private async Task<NativeVpnAccountIdentity> ResolveAccountIdentityAsync(VexAuthSession session,
        string globalId, IReadOnlyList<VpnLocation> locations, long intent, CancellationToken cancellationToken)
    {
        EnsureAccountIntent(intent, cancellationToken);
        var stored = _stateStore.AccountVpnIdentities.Load(session.User.Id);
        if (stored is not null) return stored;
        // This authenticated owner-filtered list is mandatory even when an old
        // local file has an owner tag. Neither a header ID nor a key proves ownership.
        var devices = await _api.GetDevicesAsync(session.AccessToken, cancellationToken)
            .WaitAsync(cancellationToken).ConfigureAwait(false);
        EnsureAccountIntent(intent, cancellationToken);
        var matching = devices.Where(device => device is not null &&
            LegacyExternalMatches(device.ExternalDeviceId, globalId, locations)).ToArray();
        if (matching.Any(device => device.UserId is not null && device.UserId != session.User.Id))
            throw new NativeClientFlowException("vpn_device_owner_mismatch");
        var candidates = matching.Where(device => OwnedLegacy(device, session)).ToArray();
        if (candidates.Length > 1) throw new NativeClientFlowException("vpn_legacy_identity_ambiguous");
        NativeVpnAccountIdentity identity;
        var claimLegacyKey = false;
        if (candidates.Length == 0)
        {
            var logicalId = "win-" + Guid.NewGuid().ToString("N");
            identity = new(session.User.Id, logicalId, logicalId, WireGuardIdentity.Generate());
        }
        else
        {
            var device = candidates[0];
            var legacy = _stateStore.LoadDevice();
            var canCopy = legacy is not null && legacy.InstallationId == globalId &&
                legacy.Identity.PublicKey == device.PublicKey &&
                (legacy.UserId is null || legacy.UserId == session.User.Id);
            if (device.PskEpoch is not > 0)
                throw new NativeClientFlowException("vpn_key_epoch_unavailable");
            claimLegacyKey = canCopy;
            var key = canCopy ? legacy!.Identity with { KeyEpoch = device.PskEpoch.Value } :
                WireGuardIdentity.Generate(checked(device.PskEpoch.Value + 1));
            identity = new(session.User.Id, globalId, device.ExternalDeviceId!, key, device.Id,
                legacy?.UserId == session.User.Id ? legacy.LocationId : null,
                MigrationRotationPending: !canCopy, LegacyRegistration: true);
        }
        EnsureAccountIntent(intent, cancellationToken);
        return _stateStore.AccountVpnIdentities.GetOrAdd(identity, claimLegacyKey);
    }

    private async Task<NativeVpnAccountIdentity> RegisterAccountIdentityAsync(VexAuthSession session,
        NativeVpnAccountIdentity account, string globalId, IReadOnlyList<VpnLocation> locations,
        string locationId, long intent, CancellationToken cancellationToken)
    {
        EnsureAccountIntent(intent, cancellationToken);
        if (account.MigrationRotationPending || account.PendingIdentity is not null)
            account = await RecoverAccountRotationAsync(session, account, intent, cancellationToken)
                .ConfigureAwait(false);
        if (account.DeviceId is not null)
        {
            // Creation-idempotency replay compares against the current epoch
            // before processing a new identity challenge. Synchronize an owned
            // unchanged WG pair before constructing the registration header.
            var devices = await _api.GetDevicesAsync(session.AccessToken, cancellationToken)
                .WaitAsync(cancellationToken).ConfigureAwait(false);
            EnsureAccountIntent(intent, cancellationToken);
            var own = devices.Where(candidate => candidate is not null && candidate.Id == account.DeviceId &&
                candidate.ExternalDeviceId == account.ExternalDeviceId && OwnedLegacy(candidate, session)).ToArray();
            if (own.Length != 1 || own[0].PublicKey != account.Identity.PublicKey)
                throw new NativeClientFlowException("vpn_device_owner_mismatch");
            if (own[0].PskEpoch is not > 0 || own[0].PskEpoch < account.Identity.KeyEpoch)
                throw new NativeClientFlowException("vpn_key_epoch_unavailable");
            if (own[0].PskEpoch != account.Identity.KeyEpoch)
            {
                var synchronized = account with { Identity = account.Identity with { KeyEpoch = own[0].PskEpoch!.Value } };
                _stateStore.AccountVpnIdentities.Replace(account, synchronized);
                account = synchronized;
            }
        }
        VpnDevice device;
        try
        {
            device = await RegisterAsync(account).ConfigureAwait(false);
        }
        catch (VexApiException error) when (error.StatusCode == HttpStatusCode.Conflict &&
            error.Code == "device_rebind_required" && account.LegacyRegistration && account.RegistrationId == globalId)
        {
            EnsureAccountIntent(intent, cancellationToken);
            // Re-prove the row live before repairing a historical global binding.
            // Preserve external identity and quota row while repairing the signed installation.
            var own = await _api.GetDevicesAsync(session.AccessToken, cancellationToken)
                .WaitAsync(cancellationToken).ConfigureAwait(false);
            EnsureAccountIntent(intent, cancellationToken);
            var selected = own.Where(candidate => candidate.Id == account.DeviceId &&
                candidate.ExternalDeviceId == account.ExternalDeviceId &&
                OwnedLegacy(candidate, session) && candidate.PublicKey == account.Identity.PublicKey).ToArray();
            if (selected.Length != 1 || !LegacyExternalMatches(account.ExternalDeviceId, globalId, locations)) throw;
            if (selected[0].PskEpoch is not > 0) throw new NativeClientFlowException("vpn_key_epoch_unavailable");
            // A first-use global pair may already be a peer on another account.
            // The exact foreign-binding conflict requires a fresh B pair, not
            // just another installation signature over that shared public key.
            var repaired = account with { RegistrationId = "win-" + Guid.NewGuid().ToString("N"),
                Identity = WireGuardIdentity.Generate(checked(selected[0].PskEpoch!.Value + 1)),
                MigrationRotationPending = true, LegacyRegistration = false };
            _stateStore.AccountVpnIdentities.Replace(account, repaired);
            account = repaired;
            account = await RecoverAccountRotationAsync(session, account, intent, cancellationToken, selected[0])
                .ConfigureAwait(false);
            device = await RegisterAsync(account).ConfigureAwait(false);
        }
        EnsureAccountIntent(intent, cancellationToken);
        ValidateAcknowledgement(device, session, account.Identity, account.DeviceId, allowEpochAdvance: true);
        var acknowledged = account with { DeviceId = device.Id, LocationId = locationId,
            Identity = account.Identity with { KeyEpoch = device.PskEpoch ?? account.Identity.KeyEpoch } };
        _stateStore.AccountVpnIdentities.Replace(account, acknowledged);
        return acknowledged;

        Task<VpnDevice> RegisterAsync(NativeVpnAccountIdentity identity) => _api.RegisterNativeDeviceAsync(
            session.AccessToken, identity.RegistrationId, identity.Identity.PublicKey, identity.Identity.KeyEpoch,
            locationId, _appVersion, identity.ExternalDeviceId, session.User.Id, cancellationToken)
            .WaitAsync(cancellationToken);
    }

    private async Task<NativeVpnAccountIdentity> RecoverAccountRotationAsync(VexAuthSession session,
        NativeVpnAccountIdentity account, long intent, CancellationToken cancellationToken, VpnDevice? live = null)
    {
        if (live is null)
        {
            var devices = await _api.GetDevicesAsync(session.AccessToken, cancellationToken)
                .WaitAsync(cancellationToken).ConfigureAwait(false);
            EnsureAccountIntent(intent, cancellationToken);
            var own = devices.Where(device => device is not null && device.Id == account.DeviceId &&
                device.ExternalDeviceId == account.ExternalDeviceId && OwnedLegacy(device, session)).ToArray();
            if (own.Length != 1) throw new NativeClientFlowException("vpn_device_owner_mismatch");
            live = own[0];
        }
        if (live.PskEpoch is not > 0) throw new NativeClientFlowException("vpn_key_epoch_unavailable");
        var intended = account.PendingIdentity ?? account.Identity;
        if (live.PublicKey == intended.PublicKey)
        {
            if (live.PskEpoch < intended.KeyEpoch) throw new NativeClientFlowException("vpn_key_epoch_unavailable");
            // A lost rotation response is already proven by the owner's current
            // public key. PSK-only advances do not replace this private pair.
            intended = intended with { KeyEpoch = live.PskEpoch.Value };
        }
        else
        {
            if (account.PendingIdentity is not null && live.PublicKey != account.Identity.PublicKey)
                throw new NativeClientFlowException("vpn_device_key_changed");
            intended = intended with { KeyEpoch = checked(live.PskEpoch.Value + 1) };
            var journal = account.PendingIdentity is null ? account with { Identity = intended } :
                account with { PendingIdentity = intended };
            EnsureAccountIntent(intent, cancellationToken);
            if (journal != account) _stateStore.AccountVpnIdentities.Replace(account, journal);
            account = journal;
            var rotated = await _api.RotateManagedVpnKeyAsync(session.AccessToken, account.DeviceId!,
                intended, cancellationToken).WaitAsync(cancellationToken).ConfigureAwait(false);
            EnsureAccountIntent(intent, cancellationToken);
            ValidateAcknowledgement(rotated, session, intended, account.DeviceId);
        }
        var committed = account with { Identity = intended, PendingIdentity = null, MigrationRotationPending = false };
        EnsureAccountIntent(intent, cancellationToken);
        _stateStore.AccountVpnIdentities.Replace(account, committed);
        return committed;
    }

    private static void ValidateAcknowledgement(VpnDevice? device, VexAuthSession session,
        WireGuardIdentity identity, string? expectedDeviceId, bool allowEpochAdvance = false)
    {
        if (device is null || string.IsNullOrWhiteSpace(device.Id) ||
            (expectedDeviceId is not null && device.Id != expectedDeviceId) ||
            device.UserId is not null && device.UserId != session.User.Id ||
            device.PublicKey != identity.PublicKey ||
            device.PskEpoch is not null && (allowEpochAdvance ? device.PskEpoch < identity.KeyEpoch : device.PskEpoch != identity.KeyEpoch))
            throw new VexApiException(HttpStatusCode.BadGateway, "api_response_invalid");
    }
}

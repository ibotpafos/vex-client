using System.Net;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class ProfileIdentityRecoveryTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    public static void RunMapped() => RunMappedAsync().GetAwaiter().GetResult();
    public static void RunMappedAlignment() => PskOnlyEpochPreservesKeyAndInvalidatesSpeculativeLeasesAsync(mapped: true).GetAwaiter().GetResult();
    public static void RunMappedPendingRebase() => StalePendingRotationRebasesExactKeyAsync(mapped: true).GetAwaiter().GetResult();

    private static async Task RunMappedAsync()
    {
        await PskOnlyEpochPreservesKeyAndInvalidatesSpeculativeLeasesAsync(mapped: true);
        await RotationUsesAuthoritativeNextEpochAsync(mapped: true);
        await StalePendingRotationRebasesExactKeyAsync(mapped: true);
        await AlreadyAcceptedPendingKeySurvivesFurtherPskRotationAsync(mapped: true);
        await AcceptedPendingCannotRollBackCommittedEpochAsync(mapped: true);
        await InvalidIdentityCannotMutateOrConnectAsync(mapped: true);
        await MaximumEpochCannotGenerateOrPostRotationAsync(mapped: true);
        await ReplayResponseMustMatchPendingDeviceAndKeyAsync(mapped: true);
        await PostflightProfileMustConfirmAcceptedPendingKeyAsync(mapped: true);
        await ConfirmedAcknowledgementRetainsKeyWhenPostflightFailsAsync(mapped: true);
        await CancelAtConfirmedAcknowledgementRetainsAcceptedKeyAsync(mapped: true);
        MappedEpochChangesRejectUnknownOrStaleMaterial();
    }

    private static void MappedEpochChangesRejectUnknownOrStaleMaterial()
    {
        using var fixture = new Fixture(mapped: true);
        var initial = fixture.Store.State!;
        var pending = WireGuardIdentity.Generate(2);
        fixture.Store.Save(initial with { PendingIdentity = pending });
        var map = fixture.Store.AccountVpnIdentities.Load(initial.Session.User.Id)!;
        foreach (var invalid in new[]
        {
            initial with { Identity = WireGuardIdentity.Generate(3), PendingIdentity = pending },
            initial with { Identity = initial.Identity with { KeyEpoch = 0 }, PendingIdentity = pending },
            initial with { PendingIdentity = null },
            initial with { PendingIdentity = WireGuardIdentity.Generate(3) },
            initial with { VpnRegistrationId = "another-registration", PendingIdentity = pending },
            initial with { VpnExternalDeviceId = "another-external", PendingIdentity = pending },
            initial with { DeviceId = "another-device", PendingIdentity = pending },
            initial with { Session = initial.Session with { User = initial.Session.User with { Id = "another-user" } }, PendingIdentity = pending },
        })
        {
            try { fixture.Store.Save(invalid); }
            catch (InvalidOperationException)
            {
                Check(fixture.Store.AccountVpnIdentities.Load(initial.Session.User.Id) == map &&
                    fixture.Store.State!.Identity == initial.Identity && fixture.Store.State.PendingIdentity == pending,
                    "A foreign pair, pending replacement/drop, rollback or account binding cannot replace the durable mapped journal.");
                continue;
            }
            throw new InvalidOperationException("Expected mapped identity rejection.");
        }
        var advanced = map with { Identity = map.Identity with { KeyEpoch = 3 } };
        fixture.Store.AccountVpnIdentities.Replace(map, advanced);
        var staleEpochRejected = false;
        try { fixture.Store.Save(initial with { PendingIdentity = pending }); }
        catch (InvalidOperationException)
        {
            staleEpochRejected = true;
            Check(fixture.Store.AccountVpnIdentities.Load(initial.Session.User.Id) == advanced,
                "A stale session cannot roll back a newer same-pair map epoch.");
        }
        if (!staleEpochRejected || fixture.Store.AccountVpnIdentities.Load(initial.Session.User.Id) != advanced)
            throw new InvalidOperationException("Expected stale mapped epoch rejection.");
        var staleCasRejected = false;
        try { fixture.Store.AccountVpnIdentities.Replace(map, map); }
        catch (InvalidOperationException) { staleCasRejected = true; }
        Check(staleCasRejected, "A stale map record cannot pass the actual file-store CAS.");
        var rebound = advanced with { DeviceId = "replacement-owned-device" };
        fixture.Store.AccountVpnIdentities.Replace(advanced, rebound);
        var staleDeviceRejected = false;
        try { fixture.Store.Save(initial with { Identity = advanced.Identity, PendingIdentity = pending }); }
        catch (InvalidOperationException) { staleDeviceRejected = true; }
        Check(staleDeviceRejected && fixture.Store.AccountVpnIdentities.Load(initial.Session.User.Id) == rebound,
            "A stale session with the same key and epoch cannot restore an earlier mapped device binding.");
        var restored = NativeVpnAccountIdentitySynchronization.Restore(fixture.Store.AccountVpnIdentities,
            initial with { Identity = advanced.Identity, PendingIdentity = pending, CachedAuthorization = fixture.Authorization,
                CachedProfileVersion = 7, CachedCandidatePolicyExpiresAt = DateTimeOffset.UtcNow.AddHours(1) });
        Check(restored.DeviceId == rebound.DeviceId && restored.Identity == rebound.Identity &&
            restored.CachedAuthorization is null && restored.CachedProfileVersion is null &&
            restored.CachedCandidatePolicyExpiresAt is null,
            "Restoring the authoritative mapped device must discard stale authorization and leases.");
    }

    private static async Task RunAsync()
    {
        await PskOnlyEpochPreservesKeyAndInvalidatesSpeculativeLeasesAsync();
        await RotationUsesAuthoritativeNextEpochAsync();
        await StalePendingRotationRebasesExactKeyAsync();
        await PendingEpochCannotMoveBackwardsAsync();
        await AlreadyAcceptedPendingKeySurvivesFurtherPskRotationAsync();
        await AcceptedPendingCannotRollBackCommittedEpochAsync();
        await LostRotationResponseRecoversAcceptedKeyAsync();
        await UnchangedEpochAdvanceRequestsFullAuthorityAsync();
        await InvalidIdentityCannotMutateOrConnectAsync();
        await MaximumEpochCannotGenerateOrPostRotationAsync();
        await ReplayResponseMustMatchPendingDeviceAndKeyAsync();
        await PostflightProfileMustConfirmAcceptedPendingKeyAsync();
        await ConfirmedAcknowledgementRetainsKeyWhenPostflightFailsAsync();
        await CancelAtConfirmedAcknowledgementRetainsAcceptedKeyAsync();
        await CancellationCannotCommitLateProfileOrRotationAsync();
        await ChangedAccountCannotAdoptAnotherSessionIdentityAsync();
        await LegacyProfileStillSupportsIdempotentRotationAsync();
    }

    private static async Task PskOnlyEpochPreservesKeyAndInvalidatesSpeculativeLeasesAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped);
        var original = fixture.Store.State!;
        fixture.SeedSpeculativeLeases();
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        var state = fixture.Store.State!;
        Check(state.Identity == original.Identity with { KeyEpoch = 3 } && fixture.Posted.Count == 0 &&
            fixture.Vpn.PrivateKey == original.Identity.PrivateKey && state.WarmedProfile is null &&
            state.CachedCandidateGrants is null && state.CachedCandidatePolicyExpiresAt is null,
            "A server PSK-only epoch advancement must retain the exact key pair and drop all earlier speculative leases.");
        if (mapped) Check(fixture.Store.AccountVpnIdentities.Load(state.Session.User.Id)!.Identity == state.Identity &&
            fixture.Store.LoadDevice() is null,
            "The actual account file must commit same-pair epoch alignment without overwriting a global legacy device file.");
    }

    private static async Task RotationUsesAuthoritativeNextEpochAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped) { RotationRequired = true };
        var original = fixture.Store.State!.Identity;
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted is [{ KeyEpoch: 4 }] && fixture.Store.State!.Identity.KeyEpoch == 4 &&
            fixture.Store.State.Identity.PublicKey != original.PublicKey && fixture.Store.State.PendingIdentity is null &&
            fixture.Vpn.PrivateKey == fixture.Posted[0].PrivateKey,
            "Rotation after server epoch 3 must durably generate and confirm epoch 4 before using the new private key.");
    }

    private static async Task StalePendingRotationRebasesExactKeyAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped);
        var original = fixture.Store.State!.Identity;
        var pending = WireGuardIdentity.Generate(2);
        fixture.Store.Save(fixture.Store.State with { PendingIdentity = pending });
        fixture.RotationRequest = (identity, _) =>
        {
            Check(identity == pending with { KeyEpoch = 4 } && fixture.Store.State!.PendingIdentity == identity &&
                fixture.Store.State.Identity == original && fixture.Vpn.PrivateKey is null,
                "A stale pending epoch must be rebased with the same pending private key and saved before POST without committing it.");
            if (mapped) Check(fixture.Store.AccountVpnIdentities.Load(fixture.Store.State.Session.User.Id)!.PendingIdentity == identity,
                "The actual account file must retain the rebased pending private pair before the rotation request.");
            return fixture.AcceptRotation(identity);
        };
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted is [{ KeyEpoch: 4 }] && fixture.Store.State!.Identity == pending with { KeyEpoch = 4 },
            "The previous implementation's permanently stuck pending epoch 2 must recover against server epoch 3.");
    }

    private static async Task PendingEpochCannotMoveBackwardsAsync()
    {
        foreach (var epoch in new[] { 0, 5 })
        {
            using var fixture = new Fixture();
            var pending = WireGuardIdentity.Generate(2) with { KeyEpoch = epoch };
            fixture.Store.Save(fixture.Store.State! with { PendingIdentity = pending });
            if (epoch == 0)
                await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            else
                await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Posted.Count == 0 && fixture.Store.State!.PendingIdentity == pending && fixture.Vpn.PrivateKey is null,
                "A nonpositive pending epoch or a server observation below the pending high-water mark cannot rewrite or post a key.");
        }
    }

    private static async Task AlreadyAcceptedPendingKeySurvivesFurtherPskRotationAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped);
        var pending = WireGuardIdentity.Generate(2);
        fixture.Store.Save(fixture.Store.State! with { PendingIdentity = pending });
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = 5;
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted.Count == 0 && fixture.Store.State!.Identity == pending with { KeyEpoch = 5 } &&
            fixture.Store.State.PendingIdentity is null && fixture.Vpn.PrivateKey == pending.PrivateKey,
            "An accepted pending public key followed by PSK-only rotations must retain that private key without another rotation POST.");
    }

    private static async Task AcceptedPendingCannotRollBackCommittedEpochAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped);
        var pending = WireGuardIdentity.Generate(2);
        fixture.Store.Save(fixture.Store.State! with
        { Identity = fixture.Store.State!.Identity with { KeyEpoch = 5 }, PendingIdentity = pending });
        var before = fixture.Store.State!;
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = 3;
        await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        Check(fixture.Store.State!.Identity == before.Identity && fixture.Store.State.PendingIdentity == pending &&
            fixture.Posted.Count == 0 && fixture.Vpn.PrivateKey is null,
            "An accepted pending key cannot lower the committed epoch high-water mark or admit stale authority.");
        if (mapped) Check(fixture.Store.AccountVpnIdentities.Load(before.Session.User.Id)!.Identity == before.Identity &&
            fixture.Store.AccountVpnIdentities.Load(before.Session.User.Id)!.PendingIdentity == pending,
            "Backward accepted-pending metadata must preserve both pairs in the actual map.");
    }

    private static async Task LostRotationResponseRecoversAcceptedKeyAsync()
    {
        using var fixture = new Fixture { RotationRequired = true };
        fixture.RotationRequest = (identity, cancellationToken) =>
        {
            _ = fixture.AcceptRotation(identity);
            return Task.FromException<VpnDevice>(new HttpRequestException("Response lost after server commit"));
        };
        await ExpectAsync<HttpRequestException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        var pending = fixture.Store.State!.PendingIdentity!;
        Check(fixture.Store.State.Identity.PublicKey != pending.PublicKey && fixture.Vpn.PrivateKey is null,
            "A lost response must retain durable pending material without using an unconfirmed key.");
        fixture.ServerEpoch++;
        fixture.RotationRequest = null;
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted.Count == 1 && fixture.Store.State!.Identity.PrivateKey == pending.PrivateKey &&
            fixture.Store.State.Identity.KeyEpoch == 5 && fixture.Store.State.PendingIdentity is null,
            "Fresh authoritative profile must recover the same accepted pending key even after an additional PSK rotation.");
    }

    private static async Task UnchangedEpochAdvanceRequestsFullAuthorityAsync()
    {
        using var fixture = new Fixture();
        var state = fixture.Store.State!;
        fixture.Store.Save(state with { CachedProfileVersion = 7, CachedAuthorization = fixture.Authorization,
            CachedCandidatePolicyExpiresAt = DateTimeOffset.UtcNow.AddHours(-1) });
        fixture.ProfileRequest = _ => Task.FromResult(fixture.Profile() with
        { Unchanged = fixture.ProfileCalls == 1, Authorization = fixture.ProfileCalls == 1 ? null : fixture.Authorization });
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.KnownVersions.SequenceEqual(new int?[] { null, null }) && fixture.ProfileCalls == 2 &&
            fixture.Store.State!.Identity.KeyEpoch == 3 && fixture.Vpn.Authorization == fixture.Authorization.ToServiceAuthorization(),
            "Epoch advancement in a compact response must drop obsolete cached authority and fetch a full grant before Connect.");
    }

    private static async Task InvalidIdentityCannotMutateOrConnectAsync(bool mapped = false)
    {
        foreach (var mutate in new Func<ManagedVpnProfile, ManagedVpnProfile>[]
        {
            profile => profile with { DeviceId = "foreign-device" },
            profile => profile with { Version = 0 },
            profile => profile with { ClientPublicKey = "foreign-public-key" },
            profile => profile with { ClientPublicKey = null },
            profile => profile with { ClientKeyEpoch = null },
            profile => profile with { ClientKeyEpoch = 0 },
            profile => profile with { ClientKeyEpoch = -1 },
            profile => profile with { ClientKeyEpoch = 1 },
        })
        {
            using var fixture = new Fixture(mapped);
            fixture.Store.Save(fixture.Store.State! with { Identity = fixture.Store.State!.Identity with { KeyEpoch = 2 } });
            var original = fixture.Store.State;
            fixture.ProfileRequest = _ => Task.FromResult(mutate(fixture.Profile()));
            await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Store.State!.Identity == original!.Identity && fixture.Store.State.PendingIdentity is null &&
                fixture.Posted.Count == 0 && fixture.Vpn.Authorization is null,
                "Foreign, partial, nonpositive or backward identity metadata must not mutate keys or execute a tunnel.");
        }
        using var pendingFixture = new Fixture(mapped);
        var pending = WireGuardIdentity.Generate(2);
        pendingFixture.Store.Save(pendingFixture.Store.State! with { PendingIdentity = pending });
        pendingFixture.ServerPublicKey = WireGuardIdentity.Generate().PublicKey;
        await ExpectAsync<VexApiException>(() => pendingFixture.Coordinator.ConnectAsync(CancellationToken.None));
        Check(pendingFixture.Posted.Count == 0 && pendingFixture.Store.State!.PendingIdentity == pending &&
            pendingFixture.Vpn.PrivateKey is null, "A third-party public key cannot replace either committed or pending private material.");
    }

    private static async Task MaximumEpochCannotGenerateOrPostRotationAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped) { ServerEpoch = int.MaxValue, RotationRequired = true };
        var original = fixture.Store.State!.Identity;
        await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "vpn_key_rotation_failed");
        Check(fixture.Posted.Count == 0 && fixture.Store.State!.PendingIdentity is null &&
            fixture.Store.State.Identity.PrivateKey == original.PrivateKey && fixture.Vpn.PrivateKey is null,
            "Maximum epoch must produce a bounded flow failure before key generation or rotation POST.");
    }

    private static async Task ReplayResponseMustMatchPendingDeviceAndKeyAsync(bool mapped = false)
    {
        foreach (var invalid in new Func<WireGuardIdentity, VpnDevice>[]
        {
            identity => new("other-device", "Windows", "active", identity.PublicKey),
            _ => new("test-device", "Windows", "active", WireGuardIdentity.Generate().PublicKey),
            identity => new("test-device", "Windows", "active", identity.PublicKey, UserId: "other-user"),
            identity => new("test-device", "Windows", "active", identity.PublicKey, PskEpoch: identity.KeyEpoch - 1),
        })
        {
            using var fixture = new Fixture(mapped) { RotationRequired = true };
            fixture.RotationRequest = (identity, _) => Task.FromResult(invalid(identity));
            await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            Check(fixture.Store.State!.Identity.PublicKey == fixture.ServerPublicKey &&
                fixture.Store.State.PendingIdentity is not null && fixture.Vpn.PrivateKey is null,
                "HTTP 200 replay with a foreign device, key, owner or backward epoch must not commit pending identity.");
        }
    }

    private static async Task PostflightProfileMustConfirmAcceptedPendingKeyAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped) { RotationRequired = true };
        fixture.RotationRequest = (identity, _) => Task.FromResult(new VpnDevice("test-device", "Windows", "active", identity.PublicKey));
        await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        Check(fixture.Store.State!.PendingIdentity is null && fixture.Store.State.Identity == fixture.Posted.Single() &&
            fixture.Vpn.PrivateKey is null, "A matching POST confirms the retained private key, but an inconsistent fresh profile must still prevent Connect.");
    }

    private static async Task ConfirmedAcknowledgementRetainsKeyWhenPostflightFailsAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped) { RotationRequired = true };
        fixture.ProfileRequest = _ => fixture.Posted.Count == 0 ? Task.FromResult(fixture.Profile()) :
            Task.FromException<ManagedVpnProfile>(new HttpRequestException("Postflight unavailable"));
        await ExpectAsync<HttpRequestException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        Check(fixture.Store.State!.Identity == fixture.Posted.Single() && fixture.Store.State.PendingIdentity is null &&
            (mapped ? fixture.Store.AccountVpnIdentities.Load(fixture.Store.State.Session.User.Id)!.Identity : fixture.Store.LoadDevice()!.Identity) == fixture.Posted.Single() && fixture.Vpn.PrivateKey is null,
            "A confirmed rotation key must survive a later profile outage in retained device state without premature Connect.");
        fixture.ProfileRequest = null;
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted.Count == 1 && fixture.Vpn.PrivateKey == fixture.Posted.Single().PrivateKey,
            "Recovery after postflight outage reuses the confirmed private key without generating another rotation.");
    }

    private static async Task CancelAtConfirmedAcknowledgementRetainsAcceptedKeyAsync(bool mapped = false)
    {
        using var fixture = new Fixture(mapped) { RotationRequired = true };
        using var cancellation = new CancellationTokenSource();
        fixture.RotationRequest = (identity, _) =>
        {
            var result = fixture.AcceptRotation(identity);
            cancellation.Cancel();
            return result;
        };
        await ExpectAsync<OperationCanceledException>(() => fixture.Coordinator.ConnectAsync(cancellation.Token));
        Check(fixture.Store.State!.Identity == fixture.Posted.Single() && fixture.Store.State.PendingIdentity is null &&
            (mapped ? fixture.Store.AccountVpnIdentities.Load(fixture.Store.State.Session.User.Id)!.Identity : fixture.Store.LoadDevice()!.Identity) == fixture.Posted.Single() && fixture.Vpn.PrivateKey is null,
            "Cancellation at a valid ACK must retain the accepted private key while preventing profile requests and Connect.");
    }

    private static async Task CancellationCannotCommitLateProfileOrRotationAsync()
    {
        foreach (var atRotation in new[] { false, true })
        {
            using var fixture = new Fixture { RotationRequired = true };
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var lateProfile = new TaskCompletionSource<ManagedVpnProfile>(TaskCreationOptions.RunContinuationsAsynchronously);
            var lateRotation = new TaskCompletionSource<VpnDevice>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (atRotation) fixture.RotationRequest = (_, _) => { entered.SetResult(); return lateRotation.Task; };
            else fixture.ProfileRequest = _ => { entered.SetResult(); return lateProfile.Task; };
            using var cancellation = new CancellationTokenSource();
            var connect = fixture.Coordinator.ConnectAsync(cancellation.Token);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            cancellation.Cancel();
            if (atRotation) lateRotation.SetResult(new("test-device", "Windows", "active", fixture.Store.State!.PendingIdentity!.PublicKey));
            else lateProfile.SetResult(fixture.Profile());
            await ExpectAsync<OperationCanceledException>(() => connect);
            Check(fixture.Store.State!.Identity.PublicKey == fixture.ServerPublicKey && fixture.Vpn.PrivateKey is null,
                "Late profile or rotation responses after cancellation cannot commit a key or begin a tunnel.");
        }
    }

    private static async Task ChangedAccountCannotAdoptAnotherSessionIdentityAsync()
    {
        using var fixture = new Fixture();
        fixture.ProfileRequest = _ =>
        {
            var profile = fixture.Profile();
            fixture.Store.Save(fixture.Store.State! with { Session = new(new("other-user", "other@example.test", "active"), "other-token", DateTimeOffset.UtcNow.AddHours(1)) });
            return Task.FromResult(profile);
        };
        await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "session_changed");
        Check(fixture.Store.State!.Session.User.Id == "other-user" && fixture.Store.State.Identity.KeyEpoch == 1 &&
            fixture.Vpn.PrivateKey is null, "An account changing while awaiting a profile cannot inherit the previous response's epoch.");
    }

    private static async Task LegacyProfileStillSupportsIdempotentRotationAsync()
    {
        using var fixture = new Fixture { ServerEpoch = 1, RotationRequired = true, LegacyMetadata = true };
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Posted is [{ KeyEpoch: 2 }] && fixture.Store.State!.Identity == fixture.Posted[0] &&
            fixture.Store.State.PendingIdentity is null, "Servers omitting both identity fields retain the prior foreground rotation contract.");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string? _directory;
        public MemoryClientStateStore Store { get; }
        public FakeVpnControlClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; }
        public int ServerEpoch { get; set; } = 3;
        public string ServerPublicKey { get; set; }
        public bool RotationRequired { get; set; }
        public bool LegacyMetadata { get; set; }
        public int ProfileCalls { get; private set; }
        public List<int?> KnownVersions { get; } = [];
        public List<WireGuardIdentity> Posted { get; } = [];
        public Func<CancellationToken, Task<ManagedVpnProfile>>? ProfileRequest { get; set; }
        public Func<WireGuardIdentity, CancellationToken, Task<VpnDevice>>? RotationRequest { get; set; }
        public ManagedVpnProfileAuthorization Authorization => new("fixture", "ECDSA_P256_SHA256_DER",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { profile_version = 7,
                device_id = "test-device", requested_location_id = "fi-1", routing_mode = "full", bypass_region = "" }))), "c2ln");

        public Fixture(bool mapped = false)
        {
            var identity = WireGuardIdentity.Generate();
            ServerPublicKey = identity.PublicKey;
            IVpnAccountIdentityStore? accounts = null;
            if (mapped)
            {
                _directory = Path.Combine(Path.GetTempPath(), "vex-mapped-profile-recovery-" + Guid.NewGuid().ToString("N"));
                accounts = new NativeVpnAccountIdentityFileStore(Path.Combine(_directory, "accounts.bin"),
                    bytes => bytes.ToArray(), bytes => bytes.ToArray());
                accounts.GetOrAdd(new("test-user", "registration", "external", identity, "test-device", "fi-1"));
            }
            Store = new(accounts);
            Store.Save(new(new(new("test-user", "test@example.test", "active"), "test-token", DateTimeOffset.UtcNow.AddHours(1)),
                "installation", "test-device", "fi-1", identity,
                VpnRegistrationId: mapped ? "registration" : null, VpnExternalDeviceId: mapped ? "external" : null));
            var (api, proxy) = NativeApiProxy.Wrap(new FakeNativeClientApi());
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
            {
                ProfileCalls++; KnownVersions.Add((int?)args[5]);
                return ProfileRequest?.Invoke((CancellationToken)args[6]!) ?? Task.FromResult(Profile());
            };
            proxy.Overrides[nameof(INativeClientApi.RotateManagedVpnKeyAsync)] = args =>
            {
                var pending = (WireGuardIdentity)args[2]!;
                Posted.Add(pending);
                return RotationRequest?.Invoke(pending, (CancellationToken)args[3]!) ?? AcceptRotation(pending);
            };
            Coordinator = new(api, Store, Vpn, "0.1.74");
        }

        public ManagedVpnProfile Profile() => new(7, "test-device", false, RotationRequired, Authorization,
            ClientPublicKey: LegacyMetadata ? null : ServerPublicKey, ClientKeyEpoch: LegacyMetadata ? null : ServerEpoch);

        public Task<VpnDevice> AcceptRotation(WireGuardIdentity identity)
        {
            Check(identity.KeyEpoch == ServerEpoch + 1, "Rotation must use the actual backend's next server epoch contract.");
            ServerPublicKey = identity.PublicKey; ServerEpoch = identity.KeyEpoch; RotationRequired = false;
            return Task.FromResult(new VpnDevice("test-device", "Windows", "active", identity.PublicKey));
        }

        public void Dispose()
        {
            if (_directory is not null && Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        }

        public void SeedSpeculativeLeases()
        {
            var state = Store.State!;
            Store.Save(state with
            {
                WarmedProfile = new(state.Session.User.Id, state.DeviceId, state.LocationId, "split", null,
                    state.Identity.PublicKey, state.Identity.KeyEpoch, 7, Authorization, DateTimeOffset.UtcNow.AddHours(1)),
                CachedCandidateGrants = [new("candidate", "node", "198.51.100.1:443", state.Session.User.Id,
                    state.DeviceId, state.LocationId, "full", null, state.Identity.PublicKey, state.Identity.KeyEpoch,
                    7, Authorization, DateTimeOffset.UtcNow.AddHours(1), DateTimeOffset.UtcNow.AddHours(1))],
                CachedCandidatePolicyExpiresAt = DateTimeOffset.UtcNow.AddHours(1),
            });
        }
    }

    private static async Task ExpectAsync<T>(Func<Task> operation, Func<T, bool>? predicate = null) where T : Exception
    {
        try { await operation().WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (T error) when (predicate?.Invoke(error) ?? true) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }

    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
}

using System.Net;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class RetainedDeviceIdentityRecoveryTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        foreach (var run in new Func<Task>[]
        {
            AcceptedLostResponseSurvivesLogoutAndColdRestartAsync,
            AcceptedPendingSurvivesReauthenticationWithoutLogoutAsync,
            SessionWriteFailureAfterAckKeepsAcceptedDeviceRecoveryAsync,
            UnacceptedPendingRebasesBeforeRegistrationAsync,
            PskOnlyAdvanceAlignsRegistrationReplayAsync,
            DirectProvisioningRecoversBeforeRegistrationAsync,
            AnotherAccountCannotAdoptRetainedMaterialAsync,
            LegacyDeviceFilesKeepTheirRegistrationContractAsync,
            OwnerlessAcceptedPendingUsesAuthenticatedOwnershipAsync,
            InvalidProfileCannotRegisterOrDestroyPendingAsync,
            ProfileAndPersistenceFailuresPreserveAuthenticationAsync,
            CanceledOrSupersededRecoveryCannotRegisterAsync,
            RetainedDeviceChangingDuringRecoveryCannotRegisterAsync,
            CancellationAfterDurableRecoveryCannotRegisterAsync,
            AccountChangingDuringDurableRecoveryCannotRegisterAsync,
            RecoveryUsesTheSelectedAvailableLocationAsync,
            RegistrationMustConfirmTheOwnedDeviceAndKeyAsync,
        })
        {
            try { await run(); }
            catch (Exception error) { throw new InvalidOperationException(run.Method.Name + ": " + error.Message, error); }
        }
        FailedRetainedWriteCannotReplaceAuthenticatedState();
    }

    private static async Task AcceptedLostResponseSurvivesLogoutAndColdRestartAsync()
    {
        var fixture = new Fixture { RotationRequired = true, LoseRotationResponseOnce = true };
        await ExpectAsync<HttpRequestException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        var pending = fixture.Store.LoadDevice()!.PendingIdentity!;
        Check(pending == fixture.Store.Load()!.PendingIdentity && fixture.ServerPublicKey == pending.PublicKey &&
            fixture.Vpn.PrivateKey is null, "The shared App mapper must retain the exact pending private key before an ambiguous rotation.");
        await fixture.Coordinator.SignOutAsync(CancellationToken.None);
        Check(fixture.Store.Load() is null && fixture.Store.LoadDevice()!.PendingIdentity == pending,
            "Logout must remove only the session, leaving both committed and pending device identities.");
        fixture.ServerEpoch++;
        fixture.RestartFromSerializedFiles();
        Check(fixture.Store.LoadDevice()!.PendingIdentity == pending,
            "Independent JSON file roundtrip and a cold store must preserve pending private material.");
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.Store.Load()!.Identity == pending with { KeyEpoch = fixture.ServerEpoch } &&
            fixture.Store.LoadDevice()!.PendingIdentity is null && fixture.Rotations.Count == 1 &&
            fixture.Registrations.Single() == (pending.PublicKey, fixture.ServerEpoch) &&
            fixture.Vpn.PrivateKey == pending.PrivateKey,
            "After lost ACK, logout and further PSK rotation, reauth must register and connect the same accepted private key without another rotation.");
    }

    private static async Task AcceptedPendingSurvivesReauthenticationWithoutLogoutAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = pending.KeyEpoch;
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session with { AccessToken = "renewed-token" }, CancellationToken.None);
        Check(fixture.Store.LoadDevice()!.PendingIdentity == pending && fixture.Store.Load()!.VpnProvisioningPending,
            "Accepting another same-account session must preserve independently retained pending recovery.");
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Vpn.PrivateKey == pending.PrivateKey && fixture.Rotations.Count == 0,
            "Reauthentication without Clear must also adopt an already accepted pending key.");
    }

    private static async Task SessionWriteFailureAfterAckKeepsAcceptedDeviceRecoveryAsync()
    {
        var fixture = new Fixture { RotationRequired = true, FailSessionWriteAfterRotation = true };
        await ExpectAsync<IOException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        var accepted = fixture.Rotations.Single();
        Check(fixture.Store.LoadDevice()!.Identity == accepted && fixture.Store.LoadDevice()!.PendingIdentity is null &&
            fixture.Store.Load()!.PendingIdentity == accepted && fixture.Store.Load()!.Identity.PublicKey != accepted.PublicKey &&
            fixture.Vpn.PrivateKey is null,
            "A session-write failure after ACK must preserve the accepted private key in the newer retained file and the prior pending session.");
        fixture.Store.Clear();
        fixture.RestartFromSerializedFiles();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Rotations.Count == 1 && fixture.Registrations.Single() == (accepted.PublicKey, accepted.KeyEpoch) &&
            fixture.Vpn.PrivateKey == accepted.PrivateKey && fixture.Store.Load()!.PendingIdentity is null,
            "Clear and cold reauth must recover the newer confirmed retained snapshot without replaying its completed rotation.");
    }

    private static async Task UnacceptedPendingRebasesBeforeRegistrationAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        await fixture.Coordinator.SignOutAsync(CancellationToken.None);
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        fixture.BeforeRegister = () =>
        {
            var retained = fixture.Store.LoadDevice()!;
            Check(retained.Identity == fixture.Original with { KeyEpoch = 3 } &&
                retained.PendingIdentity == pending with { KeyEpoch = 4 } &&
                fixture.Store.Load()!.VpnProvisioningPending && fixture.Store.Load()!.DeviceId == string.Empty &&
                fixture.Rotations.Count == 0,
                "Unaccepted pending material must be durably rebased while authentication remains independent, before registration and without a recovery POST.");
        };
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Registrations.Single() == (fixture.Original.PublicKey, 3) &&
            fixture.Rotations.Single() == pending with { KeyEpoch = 4 } && fixture.Vpn.PrivateKey == pending.PrivateKey &&
            fixture.Store.LoadDevice()!.PendingIdentity is null,
            "The ordinary bound rotation path must finish the same rebased pending identity after registering the authoritative old key.");
    }

    private static async Task PskOnlyAdvanceAlignsRegistrationReplayAsync()
    {
        var fixture = new Fixture();
        await fixture.Coordinator.SignOutAsync(CancellationToken.None);
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Registrations.Single() == (fixture.Original.PublicKey, 3) && fixture.Rotations.Count == 0 &&
            fixture.Store.LoadDevice()!.Identity == fixture.Original with { KeyEpoch = 3 } &&
            fixture.Vpn.PrivateKey == fixture.Original.PrivateKey,
            "PSK-only advancement must align the retained epoch before backend registration replay, which rejects the stale original epoch.");
    }

    private static async Task DirectProvisioningRecoversBeforeRegistrationAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = 4;
        fixture.Store.Clear();
        var result = await fixture.Coordinator.ProvisionAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        Check(result.Identity == pending with { KeyEpoch = 4 } && result.PendingIdentity is null &&
            fixture.Registrations.Single() == (pending.PublicKey, 4) && fixture.Rotations.Count == 0 &&
            fixture.Vpn.PrivateKey is null,
            "The legacy explicit provision entry must recover identity before registration without starting or rotating a tunnel.");
    }

    private static async Task AnotherAccountCannotAdoptRetainedMaterialAsync()
    {
        var fixture = new Fixture();
        fixture.SeedPending();
        var previous = fixture.Store.LoadDevice();
        fixture.Store.Clear();
        var other = new VexAuthSession(new("other-user", "other@example.test", "active"), "other-token",
            DateTimeOffset.UtcNow.AddHours(1));
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(other, CancellationToken.None);
        await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "device_binding_conflict");
        Check(fixture.Store.Load()!.Session == other && fixture.Store.Load()!.VpnProvisioningPending &&
            fixture.Store.Load()!.Identity.PublicKey != previous!.Identity.PublicKey &&
            fixture.Store.LoadDevice() == previous && fixture.ProfileCalls == 0 && fixture.Rotations.Count == 0 &&
            fixture.Vpn.PrivateKey is null,
            "Another account cannot query or adopt owned pending material or replace the retained owner's file on binding conflict.");
    }

    private static async Task LegacyDeviceFilesKeepTheirRegistrationContractAsync()
    {
        foreach (var missingOwner in new[] { false, true })
        {
            var fixture = new Fixture { LegacyProfile = true, ServerEpoch = 1 };
            var legacy = fixture.Store.LoadDevice()!;
            fixture.Store.SetDeviceJson(missingOwner
                ? JsonSerializer.Serialize(new { legacy.InstallationId, legacy.DeviceId, legacy.LocationId, legacy.Identity })
                : JsonSerializer.Serialize(new { legacy.InstallationId, legacy.DeviceId, legacy.LocationId, legacy.Identity, legacy.UserId }));
            fixture.Store.Clear();
            fixture.RestartFromSerializedFiles();
            await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
            await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            Check(fixture.Registrations.Single() == (fixture.Original.PublicKey, 1) && fixture.Rotations.Count == 0 &&
                fixture.Store.LoadDevice()!.PendingIdentity is null && fixture.Vpn.PrivateKey == fixture.Original.PrivateKey,
                "Old JSON files omitting pending and optionally owner retain the legacy both-metadata-absent registration contract.");
        }
    }

    private static async Task InvalidProfileCannotRegisterOrDestroyPendingAsync()
    {
        foreach (var invalid in new Func<ManagedVpnProfile, ManagedVpnProfile>[]
        {
            profile => profile with { DeviceId = "foreign-device" },
            profile => profile with { Version = 0 },
            profile => profile with { ClientPublicKey = WireGuardIdentity.Generate().PublicKey },
            profile => profile with { ClientPublicKey = null },
            profile => profile with { ClientKeyEpoch = null },
            profile => profile with { ClientPublicKey = null, ClientKeyEpoch = null },
            profile => profile with { ClientKeyEpoch = 0 },
            profile => profile with { ClientKeyEpoch = -1 },
            profile => profile with { ClientKeyEpoch = 1 },
            profile => profile with { Revoked = true },
        })
        {
            var fixture = new Fixture();
            fixture.Store.Save(fixture.Store.Load()! with { Identity = fixture.Original with { KeyEpoch = 2 } });
            fixture.SeedPending(3);
            fixture.Store.Clear();
            await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
            var retained = fixture.Store.LoadDevice();
            fixture.ProfileTransform = invalid;
            await ExpectAsync<Exception>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
                error => error is VexApiException or NativeClientFlowException);
            Check(fixture.Store.LoadDevice() == retained && fixture.Store.Load()!.VpnProvisioningPending &&
                fixture.Store.Load()!.Session == fixture.Session && fixture.Registrations.Count == 0 &&
                fixture.Rotations.Count == 0 && fixture.Vpn.PrivateKey is null,
                "Foreign, partial, absent, revoked or backward profile identity must retain authentication and pending keys without registration.");
        }
        var maximum = new Fixture { ServerEpoch = int.MaxValue };
        maximum.SeedPending();
        maximum.Store.Clear();
        await maximum.Coordinator.AcceptAuthenticatedSessionAsync(maximum.Session, CancellationToken.None);
        await ExpectAsync<NativeClientFlowException>(() => maximum.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "vpn_key_rotation_failed");
        Check(maximum.Registrations.Count == 0 && maximum.Rotations.Count == 0 && maximum.Store.LoadDevice()!.PendingIdentity is not null,
            "Maximum server epoch cannot overflow, register stale material or discard pending recovery.");
        var acceptedBackward = new Fixture();
        var accepted = acceptedBackward.SeedPending(4);
        acceptedBackward.ServerPublicKey = accepted.PublicKey;
        acceptedBackward.ServerEpoch = 3;
        acceptedBackward.Store.Clear();
        await acceptedBackward.Coordinator.AcceptAuthenticatedSessionAsync(acceptedBackward.Session, CancellationToken.None);
        await ExpectAsync<VexApiException>(() => acceptedBackward.Coordinator.ConnectAsync(CancellationToken.None));
        Check(acceptedBackward.Registrations.Count == 0 && acceptedBackward.Store.LoadDevice()!.PendingIdentity == accepted,
            "An apparent pending-key match at an older epoch is not an accepted identity proof.");
    }

    private static async Task OwnerlessAcceptedPendingUsesAuthenticatedOwnershipAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        var legacy = fixture.Store.LoadDevice()!;
        fixture.Store.SetDeviceJson(JsonSerializer.Serialize(new
        { legacy.InstallationId, legacy.DeviceId, legacy.LocationId, legacy.Identity, legacy.PendingIdentity }));
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = pending.KeyEpoch;
        fixture.Store.Clear();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(fixture.Registrations.Single() == (pending.PublicKey, pending.KeyEpoch) &&
            fixture.Store.LoadDevice()!.UserId == fixture.Session.User.Id && fixture.Vpn.PrivateKey == pending.PrivateKey &&
            fixture.Rotations.Count == 0,
            "An ownerless file's exact authenticated device catalog may prove ownership by the accepted pending key, followed by strict profile confirmation.");
    }

    private static async Task ProfileAndPersistenceFailuresPreserveAuthenticationAsync()
    {
        foreach (var persistenceFailure in new[] { false, true })
        {
            var fixture = new Fixture();
            var pending = fixture.SeedPending();
            fixture.ServerPublicKey = pending.PublicKey;
            fixture.ServerEpoch = pending.KeyEpoch;
            fixture.Store.Clear();
            await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
            var retained = fixture.Store.LoadDevice();
            if (persistenceFailure) fixture.Store.FailDeviceWrite = true;
            else fixture.ProfileRequest = _ => Task.FromException<ManagedVpnProfile>(new HttpRequestException("Profile unavailable"));
            await ExpectAsync<Exception>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
                error => persistenceFailure ? error is IOException : error is HttpRequestException);
            Check(fixture.Store.LoadDevice() == retained && fixture.Store.Load()!.Session == fixture.Session &&
                fixture.Store.Load()!.VpnProvisioningPending && fixture.Registrations.Count == 0 && fixture.Rotations.Count == 0,
                "Failed profile queries or durable device writes must preserve the authenticated-only session and all retained private material.");
            fixture.Store.FailDeviceWrite = false;
            fixture.ProfileRequest = null;
            await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            Check(fixture.Vpn.PrivateKey == pending.PrivateKey,
                "The same authenticated session must recover after transient profile or persistence failure.");
        }
    }

    private static async Task CanceledOrSupersededRecoveryCannotRegisterAsync()
    {
        foreach (var superseded in new[] { false, true })
        {
            var fixture = new Fixture();
            fixture.SeedPending();
            fixture.Store.Clear();
            await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
            var retained = fixture.Store.LoadDevice();
            using var cancellation = new CancellationTokenSource();
            fixture.ProfileRequest = _ =>
            {
                if (superseded)
                    fixture.Store.Save(fixture.Store.Load()! with
                    { Session = new(new("other-user", "other@example.test", "active"), "other-token", DateTimeOffset.UtcNow.AddHours(1)) });
                else cancellation.Cancel();
                return Task.FromResult(fixture.Profile());
            };
            await ExpectAsync<Exception>(() => fixture.Coordinator.ConnectAsync(cancellation.Token),
                error => superseded ? error is NativeClientFlowException flow && flow.Code == "session_changed" : error is OperationCanceledException);
            Check(fixture.Store.LoadDevice() == retained && fixture.Registrations.Count == 0 && fixture.Rotations.Count == 0 &&
                fixture.Vpn.PrivateKey is null && fixture.Store.Load()!.VpnProvisioningPending,
                "Cancellation or a changed account at a late recovery response cannot persist, register or connect its key.");
        }
    }

    private static async Task RetainedDeviceChangingDuringRecoveryCannotRegisterAsync()
    {
        var fixture = new Fixture();
        fixture.SeedPending();
        fixture.Store.Clear();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        var changed = fixture.Store.LoadDevice()! with { DeviceId = "changed-device" };
        fixture.ProfileRequest = _ => { fixture.Store.SaveDevice(changed); return Task.FromResult(fixture.Profile()); };
        await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "session_changed");
        Check(fixture.Store.LoadDevice() == changed && fixture.Registrations.Count == 0 && fixture.Rotations.Count == 0,
            "Recovery must not overwrite a device file changed during its authoritative request.");
    }

    private static async Task CancellationAfterDurableRecoveryCannotRegisterAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = pending.KeyEpoch;
        fixture.Store.Clear();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        using var cancellation = new CancellationTokenSource();
        fixture.Store.AfterDeviceWrite = cancellation.Cancel;
        await ExpectAsync<OperationCanceledException>(() => fixture.Coordinator.ConnectAsync(cancellation.Token));
        Check(fixture.Store.LoadDevice()!.Identity == pending && fixture.Store.LoadDevice()!.PendingIdentity is null &&
            fixture.Store.Load()!.Session == fixture.Session && fixture.Store.Load()!.VpnProvisioningPending &&
            fixture.Registrations.Count == 0 && fixture.Rotations.Count == 0 && fixture.Vpn.PrivateKey is null,
            "Cancellation during a successful durable recovery may retain the accepted key but must prevent registration and preserve authentication.");
    }

    private static void FailedRetainedWriteCannotReplaceAuthenticatedState()
    {
        var fixture = new Fixture();
        var before = fixture.Store.Load();
        var deviceBefore = fixture.Store.LoadDevice();
        fixture.Store.FailDeviceWrite = true;
        try { fixture.Store.Save(before! with { PendingIdentity = WireGuardIdentity.Generate(2) }); }
        catch (IOException)
        {
            Check(fixture.Store.Load() == before && fixture.Store.LoadDevice() == deviceBefore,
                "A failed independent retained write must not publish a new authenticated session or lose the original identity.");
            return;
        }
        throw new InvalidOperationException("Expected retained persistence failure.");
    }

    private static async Task AccountChangingDuringDurableRecoveryCannotRegisterAsync()
    {
        var fixture = new Fixture();
        var pending = fixture.SeedPending();
        fixture.ServerPublicKey = pending.PublicKey;
        fixture.ServerEpoch = pending.KeyEpoch;
        fixture.Store.Clear();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        var other = new VexAuthSession(new("other-user", "other@example.test", "active"), "other-token",
            DateTimeOffset.UtcNow.AddHours(1));
        var otherIdentity = WireGuardIdentity.Generate();
        fixture.Store.AfterDeviceWrite = () => fixture.Store.Save(new(other, "retained-installation", string.Empty,
            string.Empty, otherIdentity, VpnProvisioningPending: true));
        await ExpectAsync<NativeClientFlowException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None),
            error => error.Code == "session_changed");
        Check(fixture.Store.Load()!.Session == other && fixture.Store.Load()!.Identity == otherIdentity &&
            fixture.Store.Load()!.VpnProvisioningPending && fixture.Store.Load()!.CachedAuthorization is null &&
            fixture.Store.LoadDevice()!.Identity == pending && fixture.Store.LoadDevice()!.UserId == fixture.Session.User.Id &&
            fixture.Registrations.Count == 0 && fixture.Rotations.Count == 0 && fixture.Vpn.PrivateKey is null,
            "An account changing during durable recovery must retain its new authenticated state and prevent registration with the previous token.");
    }

    private static async Task RecoveryUsesTheSelectedAvailableLocationAsync()
    {
        foreach (var directProvision in new[] { false, true })
        {
            var fixture = new Fixture();
            fixture.Store.Save(fixture.Store.Load()! with { LocationId = "retired-location" });
            fixture.Store.Clear();
            fixture.ProfileRequest = _ => fixture.ProfileLocations.Last() == "retired-location"
                ? Task.FromException<ManagedVpnProfile>(new VexApiException(HttpStatusCode.NotFound, "vpn_location_unavailable"))
                : Task.FromResult(fixture.Profile());
            fixture.BeforeRegister = () => Check(fixture.ProfileLocations.SequenceEqual(["fi-1"]) &&
                fixture.Store.LoadDevice()!.LocationId == "retired-location",
                "Identity preflight must use the selected available region while retaining prior preferences until verified registration.");
            if (directProvision)
                await fixture.Coordinator.ProvisionAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
            else
            {
                await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
                await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            }
            Check(fixture.Store.Load()!.LocationId == "fi-1" && fixture.Registrations.Single() == (fixture.Original.PublicKey, 3),
                "A retired retained region must not block either registration entry from recovering through a currently available region.");
        }
    }

    private static async Task RegistrationMustConfirmTheOwnedDeviceAndKeyAsync()
    {
        foreach (var directProvision in new[] { false, true })
        foreach (var wrongKey in new[] { false, true })
        {
            var fixture = new Fixture();
            var pending = fixture.SeedPending();
            fixture.Store.Clear();
            if (wrongKey) fixture.RegisteredPublicKey = WireGuardIdentity.Generate().PublicKey;
            else fixture.RegisteredDeviceId = "foreign-device";
            if (directProvision)
                await ExpectAsync<VexApiException>(() => fixture.Coordinator.ProvisionAuthenticatedSessionAsync(fixture.Session, CancellationToken.None));
            else
            {
                await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
                await ExpectAsync<VexApiException>(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
            }
            Check(fixture.Store.LoadDevice()!.DeviceId == "retained-device" &&
                fixture.Store.LoadDevice()!.PendingIdentity!.PrivateKey == pending.PrivateKey && fixture.Rotations.Count == 0 &&
                fixture.Vpn.PrivateKey is null && (directProvision ? fixture.Store.Load() is null : fixture.Store.Load()!.VpnProvisioningPending),
                "Unexpected registration IDs or keys cannot rebind another device's pending rotation or publish a completed provisioning state.");
        }
    }

    private sealed class Fixture
    {
        public WireGuardIdentity Original { get; } = WireGuardIdentity.Generate();
        public VexAuthSession Session { get; } = new(new("retained-user", "retained@example.test", "active"),
            "retained-token", DateTimeOffset.UtcNow.AddHours(1));
        public RetainingStateStore Store { get; private set; } = new();
        public FakeVpnControlClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; private set; } = null!;
        public string ServerPublicKey { get; set; }
        public int ServerEpoch { get; set; } = 3;
        public bool RotationRequired { get; set; }
        public bool LoseRotationResponseOnce { get; set; }
        public bool FailSessionWriteAfterRotation { get; set; }
        public bool LegacyProfile { get; set; }
        public int ProfileCalls { get; private set; }
        public List<(string PublicKey, int Epoch)> Registrations { get; } = [];
        public List<WireGuardIdentity> Rotations { get; } = [];
        public List<string> ProfileLocations { get; } = [];
        public string RegisteredDeviceId { get; set; } = "retained-device";
        public string? RegisteredPublicKey { get; set; }
        public Action? BeforeRegister { get; set; }
        public Func<CancellationToken, Task<ManagedVpnProfile>>? ProfileRequest { get; set; }
        public Func<ManagedVpnProfile, ManagedVpnProfile>? ProfileTransform { get; set; }
        private readonly INativeClientApi _api;

        public Fixture()
        {
            ServerPublicKey = Original.PublicKey;
            Store.Save(new(Session, "retained-installation", "retained-device", "fi-1", Original));
            var (api, proxy) = NativeApiProxy.Wrap(new FakeNativeClientApi());
            _api = api;
            proxy.Overrides[nameof(INativeClientApi.GetDevicesAsync)] = _ =>
                Task.FromResult<IReadOnlyList<VpnDevice>>([new("retained-device", "Windows", "active", ServerPublicKey)]);
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
            {
                ProfileCalls++;
                ProfileLocations.Add((string)args[2]!);
                Check((string)args[1]! == "retained-device", "Recovery must request the exact retained device.");
                return ProfileRequest?.Invoke((CancellationToken)args[^1]!) ?? Task.FromResult(Profile());
            };
            proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = args =>
            {
                BeforeRegister?.Invoke();
                var key = (string)args[2]!;
                var epoch = (int)args[3]!;
                Registrations.Add((key, epoch));
                if (Store.Load()?.Session.User.Id is { } user && user != Session.User.Id ||
                    key != ServerPublicKey || epoch != ServerEpoch)
                    return Task.FromException<VpnDevice>(new VexApiException(HttpStatusCode.Conflict, "device_binding_conflict"));
                return Task.FromResult(new VpnDevice(RegisteredDeviceId, "Windows", "active", RegisteredPublicKey ?? ServerPublicKey));
            };
            proxy.Overrides[nameof(INativeClientApi.RotateManagedVpnKeyAsync)] = args =>
            {
                var identity = (WireGuardIdentity)args[2]!;
                Check(identity.KeyEpoch == ServerEpoch + 1 && Store.LoadDevice()!.PendingIdentity == identity,
                    "Normal rotation must persist the exact pending key at the authoritative next epoch before its POST.");
                Rotations.Add(identity);
                ServerPublicKey = identity.PublicKey;
                ServerEpoch = identity.KeyEpoch;
                RotationRequired = false;
                if (FailSessionWriteAfterRotation)
                {
                    FailSessionWriteAfterRotation = false;
                    Store.RejectSessionWrite = state => state.Identity.PublicKey == identity.PublicKey && state.PendingIdentity is null;
                }
                if (LoseRotationResponseOnce)
                {
                    LoseRotationResponseOnce = false;
                    return Task.FromException<VpnDevice>(new HttpRequestException("Response lost after server commit"));
                }
                return Task.FromResult(new VpnDevice("retained-device", "Windows", "active", identity.PublicKey));
            };
            Coordinator = new(_api, Store, Vpn, "0.1.74");
        }

        public WireGuardIdentity SeedPending(int epoch = 2)
        {
            var pending = WireGuardIdentity.Generate(epoch);
            Store.Save(Store.Load()! with { PendingIdentity = pending });
            return pending;
        }

        public ManagedVpnProfile Profile()
        {
            var authorization = new ManagedVpnProfileAuthorization("fixture", "ECDSA_P256_SHA256_DER",
                Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
                { profile_version = 7, device_id = "retained-device", requested_location_id = "fi-1", routing_mode = "full", bypass_region = "" }))), "c2ln");
            var profile = new ManagedVpnProfile(7, "retained-device", false, RotationRequired, authorization,
                ClientPublicKey: LegacyProfile ? null : ServerPublicKey, ClientKeyEpoch: LegacyProfile ? null : ServerEpoch);
            return ProfileTransform?.Invoke(profile) ?? profile;
        }

        public void RestartFromSerializedFiles()
        {
            Store = Store.ColdRestart();
            Coordinator = new(_api, Store, Vpn, "0.1.74");
        }
    }

    private sealed class RetainingStateStore : IClientStateStore
    {
        private string? _sessionJson;
        private string? _deviceJson;
        public bool FailDeviceWrite { get; set; }
        public Action? AfterDeviceWrite { get; set; }
        public Func<NativeClientState, bool>? RejectSessionWrite { get; set; }
        public string GetOrCreateInstallationId() => "retained-installation";
        public ClientStateAccessKind GetAccessState() => _sessionJson is null ? ClientStateAccessKind.Missing : ClientStateAccessKind.Available;
        public NativeClientState? Load() => _sessionJson is null ? null : JsonSerializer.Deserialize<NativeClientState>(_sessionJson);
        public NativeDeviceState? LoadDevice() => _deviceJson is null ? null : JsonSerializer.Deserialize<NativeDeviceState>(_deviceJson);
        public void Save(NativeClientState state)
        {
            Check(NativeClientStateValidation.IsValid(state), "The retained persistence fixture must enforce the real App session validator.");
            if (!state.VpnProvisioningPending) SaveDevice(NativeDeviceState.FromClientState(state));
            if (RejectSessionWrite?.Invoke(state) == true) throw new IOException("Session persistence unavailable");
            _sessionJson = JsonSerializer.Serialize(state);
        }
        public void SaveDevice(NativeDeviceState state)
        {
            if (FailDeviceWrite) throw new IOException("Device persistence unavailable");
            _deviceJson = JsonSerializer.Serialize(state);
            AfterDeviceWrite?.Invoke();
        }
        public void Clear() => _sessionJson = null;
        public void SetDeviceJson(string value) => _deviceJson = value;
        public RetainingStateStore ColdRestart() => new() { _sessionJson = _sessionJson, _deviceJson = _deviceJson };
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

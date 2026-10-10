using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class ProfileWarmupTests
{
    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        ProfileDtoPreservesAuthoritativeIdentityAndLegacyCompatibility();
        ProtectedTrustPinIsRequired();
        await WarmupPreservesPreferencesAndAvoidsColdIssuanceAsync();
        await ConnectNeverWaitsForWarmupAndRejectsItsLateResponseAsync();
        await ScopeChangesRejectLateWarmupAsync();
        await SupersededWarmupCannotReplaceANewerGrantAsync();
        await InvalidAuthorityNeverEntersWarmCacheAsync();
        await PersistedWarmAuthorityIsRevalidatedAsync();
        await ColdAutomaticAppUsesExactWarmAuthorityOfflineAsync();
        await ConfirmedNegativeEntitlementSupersedesOlderPaidEvidenceAsync();
        await LateNegativeEntitlementPreservesNewerScopeAndEvidenceAsync();
    }

    private static void ProfileDtoPreservesAuthoritativeIdentityAndLegacyCompatibility()
    {
        var profile = JsonSerializer.Deserialize<ManagedVpnProfile>("""
            {"version":7,"device_id":"device-1","revoked":false,"rotation_required":false,
             "client_public_key":"authoritative-public-key","client_key_epoch":3}
            """);
        Check(profile?.ClientPublicKey == "authoritative-public-key" && profile.ClientKeyEpoch == 3,
            "The current backend response must retain authoritative key identity metadata.");
        var legacy = JsonSerializer.Deserialize<ManagedVpnProfile>("""
            {"version":7,"device_id":"device-1","revoked":false,"rotation_required":false}
            """);
        Check(legacy?.ClientPublicKey is null && legacy?.ClientKeyEpoch is null,
            "Older backend responses must remain readable for ordinary foreground Connect.");
    }

    private static void ProtectedTrustPinIsRequired()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var directory = Path.Combine(Path.GetTempPath(), "vex-profile-warmup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var keyring = Path.Combine(directory, "keys.json");
            var pin = Path.Combine(directory, "protected-pin");
            File.WriteAllText(keyring, JsonSerializer.Serialize(new
            {
                schema = "vex.profile-signing-keyring.v1",
                keys = new[] { new { key_id = "profile-key-1", algorithm = VpnSignedProfileVerifier.SupportedAlgorithm,
                    subject_public_key_info_base64 = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()) } },
            }));
            Check(ProfileWarmupTrustStore.Load(keyring, pin) is null, "An unprovisioned trust pin must disable optional warm-up.");
            File.WriteAllText(pin, new string('0', 64));
            Check(ProfileWarmupTrustStore.Load(keyring, pin) is null, "A changed keyring must never bypass the protected SHA-256 pin.");
            File.WriteAllText(pin, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(keyring))));
            Check(ProfileWarmupTrustStore.Load(keyring, pin) is not null, "The exact installer-pinned P256 keyring must load.");
            File.AppendAllText(keyring, " ");
            Check(ProfileWarmupTrustStore.Load(keyring, pin) is null, "Any keyring byte change must invalidate its pin.");
        }
        finally { Directory.Delete(directory, true); }
    }

    private static async Task WarmupPreservesPreferencesAndAvoidsColdIssuanceAsync()
    {
        using var fixture = new Fixture();
        var before = fixture.Store.State!;
        var primary = fixture.Profile("full", null).Authorization;
        fixture.Store.Save(before with { CachedProfileVersion = 7, CachedAuthorization = primary });
        Check(await fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None),
            "A signed, identity-bound profile should warm the exact requested routing scope.");
        var warmed = fixture.Store.State!;
        Check(warmed.RoutingMode == "full" && warmed.LocationId == before.LocationId &&
            warmed.SelectionMode == before.SelectionMode && warmed.CachedAuthorization == primary &&
            warmed.WarmedProfile is { RoutingMode: "split", BypassRegion: "ru" } && fixture.Vpn.Authorization is null,
            "Warm-up must preserve selected mode/location and working authorization without starting the service.");
        Check((await fixture.Coordinator.ConnectAsync("fi-1", "split", CancellationToken.None)).Success &&
            fixture.ProfileCalls == 1 && fixture.Store.State!.RoutingMode == "split" && fixture.Store.State.WarmedProfile is null,
            "The user's exact subsequent Connect must promote warmed signed authority without another profile request.");
    }

    private static async Task ConnectNeverWaitsForWarmupAndRejectsItsLateResponseAsync()
    {
        using var fixture = new Fixture();
        var entered = Signal();
        var late = new TaskCompletionSource<ManagedVpnProfile>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken warmToken = default;
        fixture.Request = (routing, bypass, token) =>
        {
            if (fixture.ProfileCalls == 1) { warmToken = token; entered.SetResult(); return late.Task; }
            return Task.FromResult(fixture.Profile(routing, bypass));
        };
        var warmup = fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None);
        await entered.Task;
        var response = await fixture.Coordinator.ConnectAsync("fi-1", "full", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
        Check(response.Success && warmToken.IsCancellationRequested && !warmup.IsCompleted,
            "Foreground Connect must cancel prefetch and complete without waiting for an uncooperative warm-up HTTP request.");
        late.SetResult(fixture.Profile("full", null));
        Check(!await warmup && fixture.Store.State!.WarmedProfile is null,
            "A late prefetched response must not change the working grant after foreground Connect wins.");
    }

    private static async Task ScopeChangesRejectLateWarmupAsync()
    {
        foreach (var mutation in new Func<NativeClientState, NativeClientState>[]
        {
            state => state with { Session = state.Session with { AccessToken = "new-access-token" } },
            state => state with { DeviceId = "replacement-device" },
            state => state with { LocationId = "de-1" },
            state => state with { RoutingMode = "split", BypassRegion = "ru" },
            state => state with { Identity = Vex.Windows.Client.Security.WireGuardIdentity.Generate(2) },
        })
        {
            using var fixture = new Fixture();
            var pending = new TaskCompletionSource<ManagedVpnProfile>(TaskCreationOptions.RunContinuationsAsynchronously);
            var profile = fixture.Profile("full", null);
            fixture.Request = (_, _, _) => pending.Task;
            var warmup = fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None);
            var changed = mutation(fixture.Store.State!);
            fixture.Store.Save(changed);
            pending.SetResult(profile);
            Check(!await warmup && fixture.Store.State == changed && changed.WarmedProfile is null,
                "Late warm-up must not overwrite changes to auth, device, location, routing, or key identity.");
        }
    }

    private static async Task SupersededWarmupCannotReplaceANewerGrantAsync()
    {
        using var fixture = new Fixture();
        var first = new TaskCompletionSource<ManagedVpnProfile>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Request = (routing, bypass, _) => fixture.ProfileCalls == 1 ? first.Task : Task.FromResult(fixture.Profile(routing, bypass));
        var old = fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None);
        Check(await fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None), "New routing scope must supersede pending issuance.");
        var current = fixture.Store.State!.WarmedProfile;
        first.SetResult(fixture.Profile("full", null));
        Check(!await old && fixture.Store.State!.WarmedProfile == current && current?.RoutingMode == "split",
            "A superseded profile cannot overwrite the newer exact-routing cache.");
    }

    private static async Task InvalidAuthorityNeverEntersWarmCacheAsync()
    {
        foreach (var mutation in new Func<ManagedVpnProfile, ManagedVpnProfile>[]
        {
            profile => profile with { ClientPublicKey = null, ClientKeyEpoch = null },
            profile => profile with { ClientPublicKey = "foreign-key" },
            profile => profile with { ClientKeyEpoch = 99 },
            profile => profile with { DeviceId = "foreign-device" },
            profile => profile with { Revoked = true },
            profile => profile with { RotationRequired = true },
            profile => profile with { Unchanged = true },
            profile => profile with { Version = 9 },
            profile => profile with { Authorization = profile.Authorization! with { SignatureBase64 = Convert.ToBase64String(new byte[64]) } },
        })
        {
            using var fixture = new Fixture();
            fixture.Request = (routing, bypass, _) => Task.FromResult(mutation(fixture.Profile(routing, bypass)));
            Check(!await fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None) &&
                fixture.Store.State!.WarmedProfile is null && fixture.Vpn.Authorization is null,
                "Unbound, foreign, revoked, rotated, unchanged, or invalidly signed profile must never be warmed or executed.");
        }
        foreach (var field in new[] { "user_id", "device_id", "requested_location_id", "assigned_location_id", "routing_mode", "bypass_region" })
        {
            using var fixture = new Fixture();
            fixture.Request = (routing, bypass, _) => Task.FromResult(fixture.Profile(routing, bypass, payload => payload[field] = "foreign"));
            Check(!await fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None),
                "Even valid P256 signatures cannot warm authority for a different signed identity or routing scope.");
        }
    }

    private static async Task PersistedWarmAuthorityIsRevalidatedAsync()
    {
        foreach (var expire in new[] { true, false })
        {
            using var fixture = new Fixture();
            Check(await fixture.Coordinator.WarmProfileAsync(null, "full", null, CancellationToken.None), "Fixture must warm a real signed grant.");
            if (expire) fixture.Now = fixture.Now.AddMinutes(15);
            else fixture.TrustAvailable = false;
            Check((await fixture.Coordinator.ConnectAsync("fi-1", "full", CancellationToken.None)).Success && fixture.ProfileCalls == 2,
                "Expired or no longer trusted persisted warm authority must fall back to ordinary cold Connect.");
        }
    }

    private static async Task ColdAutomaticAppUsesExactWarmAuthorityOfflineAsync()
    {
        foreach (var catalogStatus in new System.Net.HttpStatusCode?[]
            { null, System.Net.HttpStatusCode.RequestTimeout, System.Net.HttpStatusCode.TooManyRequests,
                System.Net.HttpStatusCode.ServiceUnavailable })
        {
            using var fixture = new Fixture();
            Check(await fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None), "Fresh profile must warm.");
            Check(fixture.Store.State!.RoutingMode == "full" && fixture.Store.State.CachedAuthorization is null &&
                fixture.Store.State.CachedEntitlement?.HasPaidAccess == true, "Warm-up must preserve full preference while caching bounded paid access.");
            fixture.GoOffline(catalogStatus: catalogStatus);
            var restarted = fixture.NewCoordinator();
            Check((await new VpnProductParityService().ConnectAsync(restarted, NativeClientPreferences.Default,
                    CancellationToken.None)).Success && fixture.ProfileCalls == 1 && fixture.Store.State.RoutingMode == "split",
                "Actual cold App path must use exact warmed split authority after network, 408, 429 or 503 catalog failure and offline issuance.");
        }
        foreach (var failure in new[] { "mode", "expiry", "entitlement", "user", "device", "key", "trust", "auth", "forbidden" })
        {
            using var fixture = new Fixture();
            Check(await fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None), "Fixture must warm.");
            var preferences = NativeClientPreferences.Default;
            var state = fixture.Store.State!;
            if (failure == "mode") preferences = preferences with { SmartRoutingEnabled = false };
            if (failure == "expiry") fixture.Now = fixture.Now.AddMinutes(15);
            if (failure == "entitlement") fixture.Store.Save(state with { CachedEntitlement = FakeNativeClientApi.NoVpnEntitlement });
            if (failure == "user") fixture.Store.Save(state with { Session = state.Session with { User = state.Session.User with { Id = "other-user" } } });
            if (failure == "device") fixture.Store.Save(state with { DeviceId = "other-device" });
            if (failure == "key") fixture.Store.Save(state with { Identity = Vex.Windows.Client.Security.WireGuardIdentity.Generate(2) });
            if (failure == "trust") fixture.TrustAvailable = false;
            fixture.GoOffline(failure == "auth", failure == "forbidden" ? System.Net.HttpStatusCode.Forbidden : null);
            try
            {
                await new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), preferences, CancellationToken.None);
                throw new InvalidOperationException("Cold App unexpectedly reused mismatched or unauthorized warm authority: " + failure);
            }
            catch (Exception error) when (error is HttpRequestException or VexApiException or NativeClientFlowException) { }
            Check(fixture.Vpn.Authorization is null && fixture.ProfileCalls == 1,
                "Actual App fallback must reject wrong mode, expiry, entitlement, identity, key, trust and catalog authentication failures.");
            if (failure == "auth") Check(fixture.Store.State is null, "A terminal refresh 401 must clear rejected session authority.");
        }
    }

    private static async Task ConfirmedNegativeEntitlementSupersedesOlderPaidEvidenceAsync()
    {
        using var fixture = new Fixture();
        var primary = fixture.Profile("full", null).Authorization;
        fixture.Store.Save(fixture.Store.State! with { CachedProfileVersion = 7, CachedAuthorization = primary,
            CachedEntitlement = new FakeNativeClientApi().Entitlement,
            CachedEntitlementCheckedAt = fixture.Now.AddMinutes(-10), CachedEntitlementValidUntil = fixture.Now.AddHours(12) });
        fixture.SetEntitlementRequest(_ => Task.FromResult(FakeNativeClientApi.NoVpnEntitlement));
        Check(!await fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None) &&
            fixture.ProfileCalls == 0 && fixture.Store.State!.CachedEntitlement?.HasPaidAccess == false &&
            fixture.Store.State.CachedEntitlementCheckedAt == fixture.Now && fixture.Store.State.CachedEntitlementValidUntil <= fixture.Now &&
            fixture.Store.State.CachedAuthorization == primary && fixture.Store.State.WarmedProfile is null,
            "A confirmed negative warm-up entitlement must replace older paid evidence while preserving working profile and routing.");
        fixture.GoOffline();
        try
        {
            await new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(),
                NativeClientPreferences.Default with { SmartRoutingEnabled = false }, CancellationToken.None);
            throw new InvalidOperationException("Old paid cache unexpectedly survived an authoritative negative probe.");
        }
        catch (HttpRequestException) { }
        Check(fixture.Vpn.Authorization is null, "Offline App Connect cannot reuse a paid cache after observed revocation.");
    }

    private static async Task LateNegativeEntitlementPreservesNewerScopeAndEvidenceAsync()
    {
        foreach (var mutation in new[] { "equal", "newer", "session", "generation" })
        {
            using var fixture = new Fixture();
            var paid = new FakeNativeClientApi().Entitlement;
            fixture.Store.Save(fixture.Store.State! with { CachedEntitlement = paid,
                CachedEntitlementCheckedAt = fixture.Now.AddMinutes(-10), CachedEntitlementValidUntil = fixture.Now.AddHours(12) });
            var entitlement = new TaskCompletionSource<VexEntitlement>();
            fixture.SetEntitlementRequest(_ => entitlement.Task);
            var warmup = fixture.Coordinator.WarmProfileAsync(null, "split", null, CancellationToken.None);
            NativeClientState expected;
            Task<IReadOnlyList<VpnLocation>>? catalog = null;
            TaskCompletionSource<IReadOnlyList<VpnLocation>>? pendingCatalog = null;
            if (mutation == "newer")
            {
                pendingCatalog = new(TaskCreationOptions.RunContinuationsAsynchronously);
                fixture.SetLocationsRequest(_ => pendingCatalog.Task);
                catalog = fixture.Coordinator.GetLocationsAsync(CancellationToken.None);
                entitlement.SetResult(FakeNativeClientApi.NoVpnEntitlement);
                Check(!warmup.IsCompleted, "Negative entitlement commit must serialize behind the active state operation.");
                fixture.Now = fixture.Now.AddSeconds(1);
            }
            expected = fixture.Store.State!;
            if (mutation is "equal" or "newer") expected = expected with { CachedEntitlementCheckedAt = fixture.Now };
            if (mutation == "session") expected = expected with { Session = expected.Session with { AccessToken = "newer-session" } };
            if (mutation == "generation") fixture.Coordinator.CancelProfileWarmup();
            fixture.Store.Save(expected);
            if (mutation != "newer") entitlement.SetResult(FakeNativeClientApi.NoVpnEntitlement);
            else { pendingCatalog!.SetResult([]); await catalog!; }
            Check(!await warmup && fixture.Store.State == expected && fixture.ProfileCalls == 0,
                "Late negative warm-up evidence must preserve equal/newer entitlement, a replaced session, or canceled generation.");
        }
    }

    private sealed class Fixture : IDisposable
    {
        private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public bool TrustAvailable { get; set; } = true;
        public MemoryClientStateStore Store { get; } = new();
        public FakeVpnControlClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; }
        private INativeClientApi Api { get; }
        private NativeApiProxy Proxy { get; }
        public int ProfileCalls { get; private set; }
        public Func<string, string?, CancellationToken, Task<ManagedVpnProfile>>? Request { get; set; }

        public Fixture()
        {
            var (api, proxy) = NativeApiProxy.Wrap(new FakeNativeClientApi());
            Api = api;
            Proxy = proxy;
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
            {
                ProfileCalls++;
                return Request?.Invoke((string)args[3]!, (string?)args[4], (CancellationToken)args[6]!) ??
                    Task.FromResult(Profile((string)args[3]!, (string?)args[4]));
            };
            Coordinator = NewCoordinator();
            Coordinator.SignInAndProvisionAsync("user@example.com", "password", CancellationToken.None).GetAwaiter().GetResult();
        }

        public NativeClientCoordinator NewCoordinator() =>
            new(Api, Store, Vpn, "1.0.0", () => Now, profileWarmupVerifier: () => TrustAvailable
                ? new VpnSignedProfileVerifier([new("profile-key-1", VpnSignedProfileVerifier.SupportedAlgorithm,
                    Convert.ToBase64String(_key.ExportSubjectPublicKeyInfo()))], () => Now) : null);

        public void SetEntitlementRequest(Func<CancellationToken, Task<VexEntitlement>> request) =>
            Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = args => request((CancellationToken)args[1]!);

        public void SetLocationsRequest(Func<CancellationToken, Task<IReadOnlyList<VpnLocation>>> request) =>
            Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = args => request((CancellationToken)args[1]!);

        public void GoOffline(bool rejectCatalogAuth = false, System.Net.HttpStatusCode? catalogStatus = null)
        {
            Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ => rejectCatalogAuth
                ? throw new VexApiException(System.Net.HttpStatusCode.Unauthorized, "auth_required")
                : catalogStatus is { } status ? throw new VexApiException(status, "catalog_unavailable")
                : throw new HttpRequestException("Catalog offline");
            if (rejectCatalogAuth) Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
                throw new VexApiException(System.Net.HttpStatusCode.Unauthorized, "auth_required");
            Proxy.Overrides[nameof(INativeClientApi.GetResiliencePolicyAsync)] = _ => throw new HttpRequestException("Policy offline");
            Proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = _ => throw new HttpRequestException("Issuance offline");
            Proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ => throw new HttpRequestException("Billing offline");
        }

        public ManagedVpnProfile Profile(string routing, string? bypass, Action<JsonObject>? mutate = null)
        {
            var state = Store.State!;
            var payload = JsonSerializer.SerializeToNode(new
            {
                schema = "vex.native-vpn-profile.v1", profile_version = 7,
                user_id = state.Session.User.Id, device_id = state.DeviceId,
                requested_location_id = state.LocationId, assigned_location_id = state.LocationId,
                routing_mode = routing, bypass_region = bypass ?? "", routing_policy_version = "fixture-v1",
                issued_at = Now, expires_at = Now.AddMinutes(10),
                tunnel = new
                {
                    protocol = "amneziawg", endpoint = "198.51.100.10:443",
                    server_public_key = Convert.ToBase64String(new byte[32]),
                    assigned_ipv4 = "10.64.1.25/32", dns = new[] { "1.1.1.1" },
                    allowed_ips = new[] { routing == "full" ? "0.0.0.0/0" : "10.0.0.0/8" },
                    mtu = 1360, persistent_keepalive = 25,
                    amnezia = new { jc = 4, jmin = 40, jmax = 70, s1 = 64, s2 = 96 },
                },
            })!.AsObject();
            mutate?.Invoke(payload);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(payload);
            var authorization = new ManagedVpnProfileAuthorization("profile-key-1", VpnSignedProfileVerifier.SupportedAlgorithm,
                Convert.ToBase64String(bytes), Convert.ToBase64String(_key.SignData(bytes, HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence)));
            return new(7, state.DeviceId, false, false, authorization, ClientPublicKey: state.Identity.PublicKey,
                ClientKeyEpoch: state.Identity.KeyEpoch);
        }

        public void Dispose() => _key.Dispose();
    }

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

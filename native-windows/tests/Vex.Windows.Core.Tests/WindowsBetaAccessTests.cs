using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class WindowsBetaAccessTests
{
    private static readonly DateTimeOffset InitialTime = new(2026, 10, 11, 12, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        LegacyPaidAndDeniedContractsAreUnchanged();
        InvalidOrIncompleteBetaGrantsCannotCreateAccess();
        IndependentAccessSourcesUseTheirOwnExpiry();
        await ActualApiRequestsNativeWindowsAccessAndParsesOldServersAsync();
        await ActualBetaConnectUsesVerifiedInstallationIdentityAsync();
        await BetaConnectRegistersWithoutBillingMutationsAsync();
        await BetaNeverBypassesTheServerDeviceQuotaAsync();
        await BetaCacheHasFreshnessAndOfflineBoundsAsync();
        await InvalidCachedLeaseCannotAdmitOfflineAsync();
        await AuthoritativeBetaRevocationSupersedesPositiveCacheAsync();
        await ActiveMonitorKeepsBetaAndDisconnectsRevokedBetaAsync();
        await BetaWarmupAndOfflineReconnectRequireBoundedAccessAsync();
        await DeniedBetaWarmupPersistsAuthoritativeRevocationAsync();
    }

    private static VexEntitlement Beta(string? endsAt = null) => FakeNativeClientApi.NoVpnEntitlement with
    {
        CurrentPeriodEnd = InitialTime.AddDays(-10).ToString("O"),
        EffectiveExpiresAt = InitialTime.AddDays(-10).ToString("O"),
        WindowsBeta = new(true, "windows", "native", "windows_free_beta_v1", endsAt, 5, false),
    };

    private static void LegacyPaidAndDeniedContractsAreUnchanged()
    {
        var paid = new FakeNativeClientApi().Entitlement;
        var accessOnly = paid with { Active = false };
        Check(paid.HasPaidAccess && paid.HasVpnAccessAt(InitialTime) && !paid.HasWindowsBetaAccess,
            "An old server paid entitlement changed its admission semantics.");
        Check(accessOnly.HasPaidAccess && accessOnly.HasVpnAccess && !accessOnly.HasWindowsBetaAccess,
            "The legacy vpn_access-only contract no longer provides paid-compatible access.");
        Check(!FakeNativeClientApi.NoVpnEntitlement.HasVpnAccess,
            "A missing beta grant created access for an unpaid account.");
        var roundTrip = JsonSerializer.Deserialize<VexEntitlement>(JsonSerializer.Serialize(Beta()))!;
        Check(roundTrip.HasWindowsBetaAccessAt(InitialTime) && roundTrip.HasVpnAccess && !roundTrip.HasPaidAccess,
            "A cold JSON restart lost the independent free beta grant or invented a paid subscription.");
        var summary = BillingSummaryBuilder.Build([new("pro_monthly", "Pro", "platega", 49900,
            "RUB", "monthly", 3, "pro", "active")], roundTrip);
        Check(summary.EntitlementStatus == "inactive" && summary.CurrentPlan is null,
            "The free beta grant was presented as a paid subscription or current paid plan.");
    }

    private static void InvalidOrIncompleteBetaGrantsCannotCreateAccess()
    {
        var valid = Beta().WindowsBeta!;
        foreach (var invalid in new[]
        {
            valid with { Active = false }, valid with { Platform = "macos" },
            valid with { Platform = "Windows" }, valid with { ClientFlavor = "expo" },
            valid with { CampaignId = null }, valid with { CampaignId = "  " },
            valid with { DeviceLimit = 0 }, valid with { DeviceLimit = -1 },
            valid with { RequiresPayment = true }, valid with { RequiresPayment = null },
            valid with { EndsAt = "not-a-date" }, valid with { EndsAt = "" },
        })
        {
            var entitlement = Beta() with { WindowsBeta = invalid };
            Check(!entitlement.HasWindowsBetaAccess && !entitlement.HasVpnAccessAt(InitialTime),
                "An invalid beta scope, payment flag, quota, campaign or expiry created access.");
            Check((new FakeNativeClientApi().Entitlement with { WindowsBeta = invalid }).HasVpnAccessAt(InitialTime),
                "Invalid optional beta metadata revoked an independent paid entitlement.");
        }
        var missingPayment = JsonSerializer.Deserialize<VexEntitlement>(
            """{"active":false,"vpn_access":false,"windows_beta":{"active":true,"platform":"windows","client_flavor":"native","campaign_id":"windows_free_beta_v1","device_limit":5,"ends_at":null}}""")!;
        Check(!missingPayment.HasVpnAccess, "Omitting the explicit no-payment flag created a free grant.");
    }

    private static void IndependentAccessSourcesUseTheirOwnExpiry()
    {
        var indefinite = Beta();
        Check(indefinite.HasVpnAccessAt(InitialTime) && indefinite.VpnAccessExpiresAt is null,
            "An expired historical subscription ended an indefinite beta grant.");
        var finite = Beta(InitialTime.AddHours(2).ToString("O"));
        Check(finite.VpnAccessExpiresAt == InitialTime.AddHours(2) && finite.HasWindowsBetaAccessAt(InitialTime) &&
            !finite.HasVpnAccessAt(InitialTime.AddHours(2)), "A finite beta grant ignored its exact expiry boundary.");
        var expired = Beta(InitialTime.AddSeconds(-1).ToString("O"));
        Check(!expired.HasWindowsBetaAccessAt(InitialTime) && !expired.HasVpnAccessAt(InitialTime),
            "An expired beta grant remained active.");
        var paid = new FakeNativeClientApi().Entitlement with
        {
            CurrentPeriodEnd = InitialTime.AddHours(1).ToString("O"),
            EffectiveExpiresAt = InitialTime.AddHours(1).ToString("O"), WindowsBeta = finite.WindowsBeta,
        };
        Check(paid.VpnAccessExpiresAt == InitialTime.AddHours(2),
            "The earlier paid expiry truncated an independent finite beta grant.");
        paid = paid with { EffectiveExpiresAt = InitialTime.AddHours(3).ToString("O") };
        Check(paid.VpnAccessExpiresAt == InitialTime.AddHours(3),
            "The earlier beta expiry truncated an independent paid subscription.");
    }

    private static async Task ActualApiRequestsNativeWindowsAccessAndParsesOldServersAsync()
    {
        foreach (var response in new[] { Beta(), new FakeNativeClientApi().Entitlement, FakeNativeClientApi.NoVpnEntitlement })
        {
            var handler = new RoutingHttpHandler(_ => new(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(response)),
            });
            var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://api.example.test") });
            var parsed = await api.GetBillingEntitlementAsync("account-token", CancellationToken.None);
            var request = handler.Requests.Single();
            Check(request.Method == HttpMethod.Get && request.RequestUri!.PathAndQuery ==
                "/v1/billing/entitlement?platform=windows&client_flavor=native" &&
                request.Headers.GetValues("X-Vex-API-Client-Version").Single() == NativeApiCompatibility.ApiClientVersion &&
                request.Headers.GetValues("X-Vex-Platform").Single() == "windows" &&
                request.Headers.Authorization?.Scheme == "Bearer" && request.Headers.Authorization.Parameter == "account-token",
                "The actual HTTP client failed to scope its authenticated entitlement request to native Windows.");
            Check(parsed.HasPaidAccess == response.HasPaidAccess && parsed.HasVpnAccessAt(InitialTime) == response.HasVpnAccessAt(InitialTime),
                "The actual HTTP decoder changed additive beta or legacy-server access semantics.");
        }
    }

    private static async Task BetaConnectRegistersWithoutBillingMutationsAsync()
    {
        using var fixture = new Fixture();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        Check(fixture.Store.State is { VpnProvisioningPending: true } && fixture.Api.RegisterCalls == 0,
            "Beta authentication reserved a device before the first Connect.");
        var result = await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        Check(result.Success && fixture.Api.RegisterCalls == 1 && fixture.Vpn.ConnectCalls == 1 &&
            fixture.Store.State is { VpnProvisioningPending: false } &&
            fixture.Store.State.CachedEntitlement is { HasWindowsBetaAccess: true, HasPaidAccess: false } &&
            fixture.Store.State.CachedEntitlementValidUntil == InitialTime.AddHours(24) && fixture.BillingMutations == 0,
            "Free beta Connect did not lazily provision the authenticated device without a checkout or payment mutation.");
    }

    private static async Task ActualBetaConnectUsesVerifiedInstallationIdentityAsync()
    {
        using var fixture = new Fixture();
        var provider = new FakeDeviceIdentityProvider();
        var verifiedRegistrations = 0;
        var handler = new RoutingHttpHandler(request => request.RequestUri!.AbsolutePath switch
        {
            "/v1/billing/entitlement" => JsonResponse(Beta()),
            "/v1/locations" => JsonResponse(fixture.Api.Locations),
            "/v1/devices" => JsonResponse(Array.Empty<VpnDevice>()),
            "/v1/devices/identity-challenge" => JsonResponse(new { id = "beta-challenge", nonce = "beta-nonce", purpose = "register" }),
            "/v1/devices/register" => Register(request),
            "/v1/vpn/profile" => JsonResponse(fixture.Profile("full", null)),
            "/v1/vpn/connected" => new(HttpStatusCode.NoContent),
            _ => new(HttpStatusCode.NotFound),
        });
        var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://api.example.test") }, provider);
        var coordinator = new NativeClientCoordinator(api, fixture.Store, fixture.Vpn, "1.0.0", () => fixture.Now);
        await coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        Check((await coordinator.ConnectAsync(CancellationToken.None)).Success && verifiedRegistrations == 1 &&
            fixture.Vpn.ConnectCalls == 1 && handler.Requests.All(request =>
                !request.RequestUri!.AbsolutePath.StartsWith("/v1/billing/", StringComparison.Ordinal) || request.Method == HttpMethod.Get),
            "The actual beta HTTP client failed verified lazy registration or initiated a billing mutation.");
        Check(handler.Requests.FindIndex(request => request.RequestUri!.AbsolutePath == "/v1/billing/entitlement") <
            handler.Requests.FindIndex(request => request.RequestUri!.AbsolutePath == "/v1/devices/identity-challenge"),
            "Actual beta provisioning requested an installation challenge before authoritative access admission.");

        HttpResponseMessage Register(HttpRequestMessage request)
        {
            using var body = JsonDocument.Parse(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
            var root = body.RootElement;
            var publicKey = root.GetProperty("public_key").GetString()!;
            var installation = root.GetProperty("installation_id").GetString()!;
            var signature = root.GetProperty("identity_signature").GetString()!;
            var expectedIdempotency = $"native-windows-register-{installation}-{root.GetProperty("key_epoch").GetInt32()}-verified-" +
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(publicKey)))[..16].ToLowerInvariant() + "-" +
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(fixture.Session.User.Id)))[..16].ToLowerInvariant();
            var payload = DeviceIdentity.SignaturePayload("beta-challenge", "beta-nonce", "register", installation,
                provider.Identity.PublicKey, publicKey);
            var normalized = signature.Replace('-', '+').Replace('_', '/');
            normalized = normalized.PadRight(normalized.Length + (4 - normalized.Length % 4) % 4, '=');
            using var verifier = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = provider.Identity.ExportPublicX(), Y = provider.Identity.ExportPublicY() },
            });
            Check(root.GetProperty("platform").GetString() == "windows" &&
                root.GetProperty("identity_public_key").GetString() == provider.Identity.PublicKey &&
                root.GetProperty("identity_key_type").GetString() == DeviceIdentity.KeyTypeP256Jwk &&
                root.GetProperty("identity_challenge_id").GetString() == "beta-challenge" &&
                request.Headers.GetValues("Idempotency-Key").Single() == expectedIdempotency &&
                verifier.VerifyData(Encoding.UTF8.GetBytes(payload), Convert.FromBase64String(normalized),
                    HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence),
                "A beta registration used a legacy identity or an unverifiable P-256 challenge signature.");
            verifiedRegistrations++;
            return JsonResponse(new { device = new VpnDevice("device-1", "Windows", "active", publicKey) });
        }
    }

    private static HttpResponseMessage JsonResponse<T>(T value) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(JsonSerializer.Serialize(value)),
    };

    private static async Task BetaNeverBypassesTheServerDeviceQuotaAsync()
    {
        using var fixture = new Fixture();
        await fixture.Coordinator.AcceptAuthenticatedSessionAsync(fixture.Session, CancellationToken.None);
        fixture.Proxy.Overrides[nameof(INativeClientApi.RegisterNativeDeviceAsync)] = _ =>
            Task.FromException<VpnDevice>(new VexApiException(HttpStatusCode.Forbidden, "vpn_device_limit_reached"));
        try
        {
            await fixture.Coordinator.ConnectAsync(CancellationToken.None);
            throw new InvalidOperationException("A server-rejected beta device quota was bypassed.");
        }
        catch (VexApiException error) when (error.Code == "vpn_device_limit_reached") { }
        Check(fixture.Vpn.ConnectCalls == 0 && fixture.ProfileCalls == 0 &&
            fixture.Store.State is { VpnProvisioningPending: true } && fixture.Store.State.Session == fixture.Session,
            "A beta quota failure requested a profile, started a tunnel or discarded the authenticated account.");
    }

    private static async Task BetaCacheHasFreshnessAndOfflineBoundsAsync()
    {
        using var fixture = new Fixture(provisioned: true);
        await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
        fixture.Now = InitialTime.AddMinutes(4);
        await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
        Check(fixture.EntitlementCalls == 1, "A fresh beta cache caused unnecessary repeated requests.");
        fixture.Now = InitialTime.AddMinutes(5);
        await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
        Check(fixture.EntitlementCalls == 2, "An aged beta cache skipped the authoritative five-minute refresh.");
        fixture.Offline = true;
        fixture.Now = InitialTime.AddHours(24).AddMinutes(4);
        await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
        fixture.Now = InitialTime.AddHours(24).AddMinutes(5);
        try
        {
            await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
            throw new InvalidOperationException("An indefinite beta grant bypassed the 24-hour offline lease.");
        }
        catch (HttpRequestException) { }
        Check(fixture.Vpn.ConnectCalls == 0 && fixture.BillingMutations == 0,
            "Entitlement refresh or offline validation mutated billing or started a tunnel.");
    }

    private static async Task InvalidCachedLeaseCannotAdmitOfflineAsync()
    {
        var admitted = new List<string>();
        foreach (var paid in new[] { false, true })
        foreach (var kind in new[] { "future-check", "overlong-lease", "missing-check" })
        {
            using var fixture = new Fixture(provisioned: true);
            if (paid) fixture.Entitlement = new FakeNativeClientApi().Entitlement;
            Check(await fixture.Coordinator.WarmProfileAsync("fi-1", "full", null, CancellationToken.None),
                "Invalid-lease controls require a genuinely signed warm profile.");
            DateTimeOffset? checkedAt = kind switch
            {
                "future-check" => fixture.Now.AddHours(1),
                "overlong-lease" => fixture.Now.AddHours(-25),
                _ => null,
            };
            fixture.Store.SetExternalSnapshot(fixture.Store.State! with
            {
                CachedEntitlementCheckedAt = checkedAt,
                CachedEntitlementValidUntil = fixture.Now.AddHours(2),
            });
            fixture.Offline = true;
            var reconnect = fixture.Coordinator.TryGetCachedReconnectLocation("full", null, out _);
            var validateRejected = false;
            var connectRejected = false;
            try { await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None); }
            catch (HttpRequestException) { validateRejected = true; }
            try { await fixture.Coordinator.ConnectAsync(CancellationToken.None); }
            catch (HttpRequestException) { connectRejected = true; }
            Console.WriteLine($"Invalid lease {(paid ? "paid" : "beta")}/{kind}: reconnect={reconnect}, validateRejected={validateRejected}, connectRejected={connectRejected}, starts={fixture.Vpn.ConnectCalls}");
            if (reconnect || !validateRejected || !connectRejected || fixture.Vpn.ConnectCalls != 0)
                admitted.Add($"{(paid ? "paid" : "beta")}/{kind}");
            Check(fixture.BillingMutations == 0 && fixture.Store.State!.Session == fixture.Session,
                "Rejecting invalid cached access must not mutate billing or discard authentication.");
        }
        Check(admitted.Count == 0, "Invalid cached leases admitted offline: " + string.Join(", ", admitted));
    }

    private static async Task AuthoritativeBetaRevocationSupersedesPositiveCacheAsync()
    {
        using var fixture = new Fixture(provisioned: true);
        await fixture.Coordinator.ConnectAsync(CancellationToken.None);
        fixture.Entitlement = fixture.Entitlement with { WindowsBeta = fixture.Entitlement.WindowsBeta! with { Active = false } };
        await fixture.Coordinator.InvalidateCachedEntitlementAsync(CancellationToken.None);
        await ExpectDeniedAsync(() => fixture.Coordinator.ConnectAsync(CancellationToken.None));
        Check(fixture.Vpn.ConnectCalls == 1 && fixture.Store.State?.CachedEntitlement?.HasVpnAccess == false &&
            fixture.Store.State.CachedEntitlementValidUntil <= fixture.Now,
            "A disabled beta replayed cached admission or lost the authoritative denial.");
    }

    private static async Task ActiveMonitorKeepsBetaAndDisconnectsRevokedBetaAsync()
    {
        using var fixture = new Fixture(provisioned: true);
        var connected = new VpnServiceResponse("connected", true, new(VpnConnectionPhase.Connected, "fi-1", 1, null), null);
        var ui = new VpnUiStateService(_ => Task.FromResult(connected));
        ui.Apply(connected);
        ui.MarkConnectionDesired(true);
        var disconnects = 0;
        var monitor = new ActiveEntitlementMonitor(fixture.Coordinator, ui, _ =>
        {
            disconnects++;
            return Task.FromResult(new VpnServiceResponse("disconnect", true, VpnConnectionSnapshot.Disconnected(2), null));
        }, () => fixture.Now);
        await monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(disconnects == 0 && ui.ConnectionDesired && ui.Snapshot.Phase == VpnConnectionPhase.Connected,
            "The active entitlement monitor disconnected a valid beta-only account.");
        fixture.Entitlement = FakeNativeClientApi.NoVpnEntitlement;
        fixture.Now = InitialTime.AddMinutes(5);
        await monitor.CheckAsync(CancellationToken.None).WaitAsync(Deadline);
        Check(disconnects == 1 && !ui.ConnectionDesired && ui.Snapshot.Phase == VpnConnectionPhase.Disconnected &&
            fixture.Store.State?.CachedEntitlement?.HasVpnAccess == false,
            "Authoritative beta removal did not invalidate admission and confirm tunnel cleanup.");
    }

    private static async Task BetaWarmupAndOfflineReconnectRequireBoundedAccessAsync()
    {
        using var fixture = new Fixture(provisioned: true);
        Check(await fixture.Coordinator.WarmProfileAsync("fi-1", "full", null, CancellationToken.None),
            "A valid beta-only account could not warm a genuinely signed profile.");
        Check(fixture.Store.State?.WarmedProfile is not null && fixture.Vpn.ConnectCalls == 0 &&
            fixture.Store.State.CachedEntitlementValidUntil == InitialTime.AddHours(24),
            "Beta warm-up executed a tunnel or omitted its bounded authoritative access lease.");
        var persisted = JsonSerializer.Deserialize<NativeClientState>(JsonSerializer.Serialize(fixture.Store.State))!;
        fixture.Store.Save(persisted);
        fixture.Offline = true;
        fixture.Now = InitialTime.AddMinutes(6);
        Check(fixture.Coordinator.TryGetCachedReconnectLocation("full", null, out var location) && location == "fi-1",
            "A cold restart lost valid signed warm-up and beta admission metadata.");
        Check((await fixture.Coordinator.ConnectAsync(CancellationToken.None)).Success &&
            fixture.Vpn.ConnectCalls == 1 && fixture.ProfileCalls == 1,
            "A bounded beta cache and valid signed warm-up could not reconnect during a control-plane outage.");
        fixture.Now = InitialTime.AddHours(24);
        Check(!fixture.Coordinator.TryGetCachedReconnectLocation("full", null, out _),
            "An expired beta offline lease exposed a cached reconnect target.");
    }

    private static async Task DeniedBetaWarmupPersistsAuthoritativeRevocationAsync()
    {
        using var fixture = new Fixture(provisioned: true);
        await fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None);
        fixture.Entitlement = FakeNativeClientApi.NoVpnEntitlement;
        fixture.Now = InitialTime.AddMinutes(6);
        Check(!await fixture.Coordinator.WarmProfileAsync("fi-1", "full", null, CancellationToken.None) &&
            fixture.ProfileCalls == 0 && fixture.Store.State?.CachedEntitlement?.HasVpnAccess == false &&
            fixture.Store.State.CachedEntitlementValidUntil <= fixture.Now,
            "Denied beta warm-up fetched a profile or retained positive access evidence.");
    }

    private static async Task ExpectDeniedAsync(Func<Task> action)
    {
        try { await action(); }
        catch (NativeClientFlowException error) when (error.Code == "vpn_entitlement_required") { return; }
        throw new InvalidOperationException("Expected authoritative VPN admission denial.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        public FakeNativeClientApi Api { get; } = new();
        public NativeApiProxy Proxy { get; }
        public MemoryClientStateStore Store { get; } = new();
        public CountingVpnClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; }
        public VexAuthSession Session { get; } = new(new("user-1", "user@example.com", "active"),
            "beta-account-token", InitialTime.AddDays(30));
        public VexEntitlement Entitlement { get; set; } = Beta();
        public DateTimeOffset Now { get; set; } = InitialTime;
        public bool Offline { get; set; }
        public int EntitlementCalls { get; private set; }
        public int ProfileCalls { get; private set; }
        public int BillingMutations { get; private set; }

        public Fixture(bool provisioned = false)
        {
            var (api, proxy) = NativeApiProxy.Wrap(Api);
            Proxy = proxy;
            proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
            {
                EntitlementCalls++;
                return Offline ? Task.FromException<VexEntitlement>(new HttpRequestException("offline")) : Task.FromResult(Entitlement);
            };
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args =>
            {
                ProfileCalls++;
                return Offline ? Task.FromException<ManagedVpnProfile>(new HttpRequestException("offline")) :
                    Task.FromResult(Profile((string)args[3]!, (string?)args[4]));
            };
            foreach (var method in new[] { nameof(INativeClientApi.CreateCheckoutSessionAsync),
                nameof(INativeClientApi.GetBillingPortalSessionAsync), nameof(INativeClientApi.CancelSubscriptionAsync) })
                proxy.Overrides[method] = _ =>
                {
                    BillingMutations++;
                    throw new InvalidOperationException("Beta access must never initiate a billing mutation.");
                };
            if (provisioned) Store.Save(new(Session, "win-installation-1", "device-1", "fi-1", WireGuardIdentity.Generate()));
            Coordinator = new(api, Store, Vpn, "1.0.0", () => Now,
                profileWarmupVerifier: () => new VpnSignedProfileVerifier([new("profile-key-1",
                    VpnSignedProfileVerifier.SupportedAlgorithm, Convert.ToBase64String(_key.ExportSubjectPublicKeyInfo()))], () => Now));
        }

        public ManagedVpnProfile Profile(string routing, string? bypass)
        {
            var state = Store.State!;
            var payload = JsonSerializer.SerializeToUtf8Bytes(new
            {
                schema = "vex.native-vpn-profile.v1", profile_version = 7,
                user_id = state.Session.User.Id, device_id = state.DeviceId,
                requested_location_id = state.LocationId, assigned_location_id = state.LocationId,
                routing_mode = routing, bypass_region = bypass ?? "", routing_policy_version = "fixture-v1",
                issued_at = Now, expires_at = Now.AddMinutes(10),
                tunnel = new
                {
                    protocol = "amneziawg", endpoint = "198.51.100.10:443",
                    server_public_key = Convert.ToBase64String(new byte[32]), assigned_ipv4 = "10.64.1.25/32",
                    dns = new[] { "1.1.1.1" }, allowed_ips = new[] { "0.0.0.0/0" }, mtu = 1360,
                    persistent_keepalive = 25, amnezia = new { jc = 4, jmin = 40, jmax = 70, s1 = 64, s2 = 96 },
                },
            });
            var grant = new ManagedVpnProfileAuthorization("profile-key-1", VpnSignedProfileVerifier.SupportedAlgorithm,
                Convert.ToBase64String(payload), Convert.ToBase64String(_key.SignData(payload, HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence)));
            return new(7, state.DeviceId, false, false, grant,
                ClientPublicKey: state.Identity.PublicKey, ClientKeyEpoch: state.Identity.KeyEpoch);
        }

        public void Dispose() => _key.Dispose();
    }

    private sealed class CountingVpnClient : IVpnControlClient
    {
        private VpnConnectionSnapshot _snapshot = VpnConnectionSnapshot.Disconnected();
        public int ConnectCalls { get; private set; }
        public Task<VpnServiceResponse> GetStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new VpnServiceResponse("status", true, _snapshot, null));
        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization, string privateKey,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ConnectCalls++;
            _snapshot = new(VpnConnectionPhase.Connected, "fi-1", ConnectCalls, null);
            return Task.FromResult(new VpnServiceResponse("connect", true, _snapshot, null));
        }
        public Task<VpnServiceResponse> DisconnectAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new VpnServiceResponse("disconnect", true, VpnConnectionSnapshot.Disconnected(), null));
    }
}

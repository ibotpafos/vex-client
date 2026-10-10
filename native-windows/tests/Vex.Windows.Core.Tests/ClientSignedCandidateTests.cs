using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class ClientSignedCandidateTests
{
    private static readonly DateTimeOffset InitialTime = new(2026, 10, 10, 12, 0, 0, TimeSpan.Zero);
    private const string DirectEndpoint = "198.51.100.10:51820";
    private const string RelayEndpoint = "198.51.100.20:51820";

    public static void Run()
    {
        CandidateApiEscapesIdentifiersAndAlwaysRequestsFreshAuthority();
        InvalidCandidateIdentifiersNeverReachHttp();
        SameExitRelayRequiresItsOwnGrantAndPreservesAntiLeak();
        ForeignAndExpiredCandidatesAreNeverRequested();
        AServerIgnoringCandidateSelectionNeverExecutesAMismatchedGrant();
        RejectedCandidateKeepsCompatibleDirectRecovery();
        AutomaticRecoveryHasAFiveServiceAttemptMaximum();
        ExpiredCachedAdmissionStillRespectsTheFiveAttemptMaximum();
        FailedGrantsPreserveWorkingAuthorityAndAttributeTheirOwnFailures();
        MissingHeaderProtectionNeverSelectsRelay();
        ActualPaidPeriodExpiryBlocksOfflineValidation();
        RenewedOnlineEntitlementIsAcceptedAfterThePreviousPeriod();
        ExpiredCachedCandidateRefreshesItsSignedProfile();
        PrefetchedRelayWorksWithoutTheControlPlane();
        PrefetchCachesAtMostThreeGrantsWithoutReplacingWorkingAuthority();
        ExpiredPrefetchedGrantNeverReachesTheService();
        ExpiredPolicyRejectsAnOtherwiseUnexpiredPrefetchedGrant();
        PrefetchedGrantsCannotCrossIdentityNodeOrRoutingScope();
        PartialPrefetchPreservesQuarantinedLeasesForOfflineRecovery();
        ProfileInvalidationClearsPrefetchedAuthority();
        ColdAutomaticAppReconnectUsesPrefetchedAuthorityOffline();
        ColdAutomaticAppNeverFallsBackAfterAnAuthenticationFailure();
        ColdAutomaticAppRejectsExpiredAndMismatchedAuthority();
        ColdAppKeepsCanonicalDirectCacheUsableAfterPolicyExpiry();
        ColdAppSkipsExpiredPrimaryAuthorityForALiveSignedRelay();
        ColdAppPreservesManualSelectionAndCallerCancellation();
    }

    private static void CandidateApiEscapesIdentifiersAndAlwaysRequestsFreshAuthority()
    {
        const string candidateId = "relay:fi-1/entry?location=de-1&known_version=99#fragment";
        var handler = new RoutingHttpHandler(request =>
        {
            Check(request.Method == HttpMethod.Get && request.RequestUri?.AbsolutePath == "/v1/vpn/profile",
                "Candidate profiles used the wrong HTTP contract.");
            Check(request.Headers.Authorization?.Scheme == "Bearer" &&
                request.Headers.Authorization?.Parameter == "access-token", "Candidate authorization was lost.");
            var query = request.RequestUri!.Query.TrimStart('?').Split('&')
                .Select(part => part.Split('=', 2)).ToDictionary(part => part[0],
                    part => Uri.UnescapeDataString(part.Length == 2 ? part[1] : string.Empty), StringComparer.Ordinal);
            Check(query["candidate_id"] == candidateId && query["device_id"] == "device-1" &&
                query["location"] == "fi-1" && query["routing_mode"] == "split" &&
                query["bypass_region"] == "ru" && query["platform"] == "windows" && query["awg_version"] == "3" &&
                !query.ContainsKey("known_version") && request.RequestUri.Fragment.Length == 0,
                "Candidate ID injection changed the requested scope or enabled an unchanged response.");
            return new(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"version\":7,\"device_id\":\"device-1\",\"revoked\":false,\"rotation_required\":false,\"authorization\":null}"),
            };
        });
        var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://vexguard.app") });
        var response = api.GetManagedVpnCandidateProfileAsync("access-token", "device-1", "fi-1", "split",
            " RU ", candidateId, CancellationToken.None).GetAwaiter().GetResult();
        Check(response.Version == 7 && handler.Requests.Count == 1, "Candidate response was not decoded.");
    }

    private static void InvalidCandidateIdentifiersNeverReachHttp()
    {
        var handler = new RoutingHttpHandler(_ => throw new InvalidOperationException("Invalid candidate reached HTTP."));
        var api = new VexApiClient(new HttpClient(handler) { BaseAddress = new("https://vexguard.app") });
        foreach (var id in new[] { " ", "relay\nentry", new string('x', 513) })
        {
            try
            {
                api.GetManagedVpnCandidateProfileAsync("token", "device-1", "fi-1", "full", null, id,
                    CancellationToken.None).GetAwaiter().GetResult();
            }
            catch (ArgumentException) { continue; }
            throw new InvalidOperationException("Invalid candidate ID was accepted.");
        }
        Check(handler.Requests.Count == 0, "Invalid candidate IDs made a network request.");
    }

    private static void SameExitRelayRequiresItsOwnGrantAndPreservesAntiLeak()
    {
        var fixture = new Fixture("tunnel_no_handshake", null);
        Check(fixture.Connect(antiLeak: false).Success, "A freshly authorized same-exit relay did not connect.");
        Check(fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, RelayEndpoint]) &&
            fixture.Requests.Select(request => request.CandidateId).SequenceEqual([null, "relay-a"]) &&
            fixture.Requests.All(request => request.LocationId == "fi-1" && request.KnownVersion is null),
            "Relay recovery changed the exit or reused another route's grant.");
        Check(fixture.Vpn.AntiLeak.All(enabled => !enabled) &&
            fixture.Store.State?.CachedAuthorization == fixture.IssuedGrants.Last(),
            "Relay recovery lost anti-leak settings or failed to persist successful authority.");
    }

    private static void ForeignAndExpiredCandidatesAreNeverRequested()
    {
        var fixture = new Fixture("tunnel_no_handshake", "tunnel_no_handshake", "tunnel_no_handshake");
        var direct = Candidate("direct", DirectEndpoint, 100);
        var relay = Candidate("relay-a", RelayEndpoint, 90);
        fixture.Policy = Policy(20, direct,
            relay with { Id = "foreign-device", DeviceId = "other-device", Priority = 999 },
            relay with { Id = "foreign-location", LocationId = "de-1", Priority = 999 },
            relay with { Id = "foreign-node", NodeId = "other-exit-node", Priority = 999 },
            relay with { Id = "foreign-protocol", ProtocolName = "wireguard", Priority = 999 },
            relay with { Id = "expired", ExpiresAt = Timestamp(InitialTime), Priority = 999 },
            relay with { Id = "invalid-expiry", ExpiresAt = "tomorrow", Priority = 999 }, relay);
        Check(!fixture.Connect().Success &&
            fixture.Requests.Where(request => request.CandidateId is not null)
                .Select(request => request.CandidateId).SequenceEqual(["relay-a"]),
            "Advisory candidates crossed device, exit, protocol or expiry boundaries.");
        Check(fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, RelayEndpoint, DirectEndpoint]),
            "Manual recovery escaped its signed exit scope.");
    }

    private static void AServerIgnoringCandidateSelectionNeverExecutesAMismatchedGrant()
    {
        var fixture = new Fixture("tunnel_no_handshake", null);
        fixture.CandidateGrantEndpoint = _ => DirectEndpoint;
        Check(fixture.Connect().Success, "An older server blocked compatible direct recovery.");
        Check(fixture.Requests.Count(request => request.CandidateId == "relay-a") == 1 &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint]) &&
            fixture.Vpn.Authorizations.All(authorization => authorization.PayloadBase64 != fixture.IssuedGrants[1].PayloadBase64),
            "A server's mismatched candidate response reached the privileged service.");
    }

    private static void RejectedCandidateKeepsCompatibleDirectRecovery()
    {
        var fixture = new Fixture("tunnel_no_handshake", null);
        fixture.CandidateError = new VexApiException(HttpStatusCode.Conflict, "vpn_profile_candidate_rejected");
        Check(fixture.Connect().Success && fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint]) &&
            fixture.Requests.Select(request => request.CandidateId).SequenceEqual([null, "relay-a", null]),
            "A stale candidate rejection prevented direct signed-profile recovery.");
    }

    private static void AutomaticRecoveryHasAFiveServiceAttemptMaximum()
    {
        var fixture = new Fixture(Enumerable.Repeat<string?>("tunnel_no_handshake", 10).ToArray());
        fixture.Policy = Policy(99, [Candidate("direct", DirectEndpoint, 100),
            .. Enumerable.Range(1, 9).Select(index => Candidate("relay-" + index,
                "198.51.100." + (20 + index) + ":51820", 99 - index))]);
        Check(!fixture.Connect(automatic: true).Success && fixture.Vpn.Endpoints.Count == 5 &&
            fixture.Requests.Count(request => request.CandidateId is not null) == 2 &&
            fixture.Requests.Select(request => request.LocationId).SequenceEqual(["fi-1", "fi-1", "fi-1", "fi-1", "de-1"]),
            "Policy max_candidates expanded recovery beyond three paths, one fresh profile and one alternate exit.");
        Check(fixture.Store.State?.CachedAuthorization is null,
            "Failed attempts persisted unconfirmed profile authority.");
    }

    private static void FailedGrantsPreserveWorkingAuthorityAndAttributeTheirOwnFailures()
    {
        var fixture = new Fixture(null, "tunnel_no_handshake", "tunnel_no_handshake", "tunnel_no_handshake");
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        var previous = fixture.Store.State!.CachedAuthorization;
        Check(!fixture.Connect().Success && fixture.Store.State?.CachedAuthorization == previous &&
            fixture.Store.State?.CachedProfileVersion == 1,
            "A failed fresh relay or direct grant replaced the last confirmed authority.");
        using var state = JsonDocument.Parse(fixture.RouteStore.Read("native.dynamicRouteState.v1")!);
        var routes = state.RootElement.GetProperty("Routes");
        Check(routes.GetProperty("direct").GetProperty("ConsecutiveFailures").GetInt32() == 2 &&
            routes.GetProperty("relay-a").GetProperty("ConsecutiveFailures").GetInt32() == 1,
            "A failed relay was attributed to the cached direct grant rather than its attempted signed endpoint.");
    }

    private static void ExpiredCachedAdmissionStillRespectsTheFiveAttemptMaximum()
    {
        var fixture = new Fixture(null, "profile_expired", "tunnel_no_handshake", "tunnel_no_handshake",
            "tunnel_no_handshake", "tunnel_no_handshake");
        fixture.Policy = Policy(99, [Candidate("direct", DirectEndpoint, 100),
            .. Enumerable.Range(1, 8).Select(index => Candidate("relay-" + index,
                "198.51.100." + (20 + index) + ":51820", 99 - index))]);
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        Check(!fixture.Connect(automatic: true).Success && fixture.Vpn.Endpoints.Count == 6 &&
            fixture.Requests.Count(request => request.CandidateId is not null) == 2,
            "Refreshing an expired cached admission added an unbudgeted sixth recovery attempt.");
    }

    private static void MissingHeaderProtectionNeverSelectsRelay()
    {
        var fixture = new Fixture("tunnel_no_handshake", "tunnel_no_handshake") { HasHeaderProtectionKey = false };
        Check(!fixture.Connect().Success && fixture.Requests.All(request => request.CandidateId is null),
            "A profile without AWG3 header protection entered relay recovery.");
    }

    private static void ActualPaidPeriodExpiryBlocksOfflineValidation()
    {
        var fixture = new Fixture((string?)null);
        fixture.Entitlement = PaidUntil(InitialTime.AddMinutes(2));
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        fixture.Now = InitialTime.AddMinutes(3);
        fixture.Offline = true;
        ExpectFlow("vpn_entitlement_required", () => fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None)
            .GetAwaiter().GetResult());
        Check(fixture.Vpn.Endpoints.Count == 1,
            "Expiry within the five-minute freshness window reached the tunnel service.");
    }

    private static void RenewedOnlineEntitlementIsAcceptedAfterThePreviousPeriod()
    {
        var fixture = new Fixture((string?)null);
        fixture.Entitlement = PaidUntil(InitialTime.AddMinutes(2));
        fixture.Coordinator.ConnectAsync(CancellationToken.None).GetAwaiter().GetResult();
        fixture.Now = InitialTime.AddMinutes(3);
        fixture.Entitlement = PaidUntil(InitialTime.AddDays(1));
        fixture.Coordinator.ValidateEntitlementAsync(CancellationToken.None).GetAwaiter().GetResult();
        Check(fixture.Store.State?.CachedEntitlementValidUntil == InitialTime.AddDays(1),
            "An online renewal remained blocked by the previous billing period.");
    }

    private static void ExpiredCachedCandidateRefreshesItsSignedProfile()
    {
        var fixture = new Fixture("tunnel_no_handshake", null, "profile_expired", null);
        Check(fixture.Connect().Success, "Initial relay fixture did not connect.");
        Check(fixture.Coordinator.ConnectAsync(null, "full", false, CancellationToken.None).GetAwaiter().GetResult().Success &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, RelayEndpoint, RelayEndpoint, DirectEndpoint]) &&
            fixture.Requests.Last().CandidateId is null && fixture.Requests.Last().KnownVersion is null,
            "Service expiry of cached relay authority did not request a fresh signed profile.");
    }

    private static void PrefetchedRelayWorksWithoutTheControlPlane()
    {
        var fixture = CachedFixture();
        Check(fixture.Connect().Success && fixture.Store.State?.CachedCandidateGrants?.Count is > 0 and <= 3,
            "Online connection did not cache a bounded set of independently signed policy grants.");
        var onlineRequests = fixture.Requests.Count;
        fixture.Offline = true;
        Check(fixture.Connect(antiLeak: false).Success &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint, RelayEndpoint]) &&
            fixture.Requests.Count == onlineRequests && fixture.Vpn.AntiLeak.Last() == false,
            "Control-plane outage prevented a valid prefetched same-exit relay or caused an unsigned replacement.");
    }

    private static void ExpiredPrefetchedGrantNeverReachesTheService()
    {
        var fixture = CachedFixture();
        fixture.Connect();
        fixture.Now = InitialTime.AddMinutes(11);
        fixture.Offline = true;
        ExpectOfflineRecoveryFailure(fixture);
        Check(fixture.Vpn.Endpoints.All(endpoint => endpoint == DirectEndpoint),
            "An expired prefetched relay reached the privileged service.");
    }

    private static void PrefetchCachesAtMostThreeGrantsWithoutReplacingWorkingAuthority()
    {
        var fixture = new Fixture((string?)null) { CacheableGrants = true };
        fixture.Policy = Policy(99, [Candidate("direct", DirectEndpoint, 100),
            .. Enumerable.Range(1, 8).Select(index => Candidate("relay-" + index,
                "198.51.100." + (20 + index) + ":51820", 99 - index))]);
        Check(fixture.Connect().Success, "Bounded prefetch fixture did not connect.");
        var state = fixture.Store.State!;
        Check(state.CachedCandidateGrants?.Count == 3 && fixture.Requests.Count == 3 &&
            fixture.Requests.Count(request => request.CandidateId is not null) == 2 &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint]) && state.CachedAuthorization == fixture.IssuedGrants[0] &&
            state.CachedCandidateGrants!.All(grant => grant.UserId == state.Session.User.Id &&
                grant.ClientPublicKey == state.Identity.PublicKey && grant.ClientKeyEpoch == state.Identity.KeyEpoch &&
                grant.ExpiresAt == InitialTime.AddMinutes(10)),
            "An advisory policy expanded prefetch, executed prefetched grants or replaced working authority.");
    }

    private static void ExpiredPolicyRejectsAnOtherwiseUnexpiredPrefetchedGrant()
    {
        var fixture = CachedFixture();
        fixture.Policy = fixture.Policy with { ExpiresAt = Timestamp(InitialTime.AddSeconds(30)) };
        fixture.Connect();
        Check(fixture.Store.State?.CachedCandidateGrants?.Any(grant => grant.Endpoint == RelayEndpoint &&
            grant.ExpiresAt > InitialTime.AddMinutes(1)) == true,
            "Policy-expiry fixture lacks an otherwise unexpired signed relay grant.");
        fixture.Now = InitialTime.AddMinutes(1);
        fixture.Offline = true;
        ExpectOfflineRecoveryFailure(fixture);
        Check(fixture.Vpn.Endpoints.All(endpoint => endpoint == DirectEndpoint),
            "An expired policy authorized reuse of a prefetched relay grant.");
    }

    private static void PrefetchedGrantsCannotCrossIdentityNodeOrRoutingScope()
    {
        foreach (var scope in new[] { "identity", "node", "routing", "user", "header", "psk" })
        {
            var fixture = CachedFixture();
            fixture.Connect();
            var state = fixture.Store.State!;
            Check(state.CachedCandidateGrants?.Any(grant => grant.Endpoint == RelayEndpoint) == true,
                "The scope-rejection fixture has no prefetched relay grant.");
            switch (scope)
            {
                case "identity":
                    fixture.Store.Save(state with { Identity = WireGuardIdentity.Generate(state.Identity.KeyEpoch + 1) });
                    break;
                case "node":
                    fixture.Policy = fixture.Policy with
                    {
                        Candidates = fixture.Policy.Candidates.Select(candidate => candidate with { NodeId = "new-exit-node" }).ToArray(),
                    };
                    fixture.Coordinator.GetResiliencePolicyAsync(CancellationToken.None).GetAwaiter().GetResult();
                    break;
                case "user":
                    fixture.Store.Save(state with
                    {
                        Session = state.Session with { User = state.Session.User with { Id = "another-user" } },
                    });
                    break;
                case "header":
                case "psk":
                    var payload = JsonNode.Parse(Encoding.UTF8.GetString(
                        Convert.FromBase64String(state.CachedAuthorization!.PayloadBase64)))!;
                    if (scope == "header")
                    {
                        payload["tunnel"]!["amnezia"]!["header_protection_key"] = "ChangedSignedHeaderKey";
                    }
                    else
                    {
                        payload["tunnel"]!["preshared_key"] = "ChangedSignedPsk";
                    }
                    fixture.Store.Save(state with
                    {
                        CachedAuthorization = state.CachedAuthorization! with
                        {
                            PayloadBase64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(payload.ToJsonString())),
                        },
                    });
                    break;
                default:
                    fixture.Store.Save(state with
                    {
                        CachedCandidateGrants = state.CachedCandidateGrants!.Select(grant => grant with { RoutingMode = "split" }).ToArray(),
                    });
                    break;
            }
            fixture.Offline = true;
            ExpectOfflineRecoveryFailure(fixture);
            Check(fixture.Vpn.Endpoints.All(endpoint => endpoint == DirectEndpoint),
                "Prefetched relay authority crossed " + scope + " scope.");
        }
    }

    private static void ProfileInvalidationClearsPrefetchedAuthority()
    {
        var fixture = CachedFixture();
        fixture.Connect();
        Check(fixture.Store.State?.CachedCandidateGrants?.Count > 0, "Profile invalidation fixture has no candidate pool.");
        fixture.Coordinator.InvalidateProfileAsync(CancellationToken.None).GetAwaiter().GetResult();
        Check(fixture.Store.State?.CachedAuthorization is null && fixture.Store.State?.CachedProfileVersion is null &&
            fixture.Store.State?.CachedCandidateGrants?.Count is null or 0,
            "Profile invalidation retained prefetched signed authority.");
    }

    private static void PartialPrefetchPreservesQuarantinedLeasesForOfflineRecovery()
    {
        var fixture = new Fixture(null, null, "tunnel_no_handshake", null) { CacheableGrants = true };
        fixture.Policy = fixture.Policy with { Probe = fixture.Policy.Probe with { FailureThreshold = 2, QuarantineMs = 30_000 } };
        Check(fixture.Connect().Success, "Initial quarantine fixture did not connect.");
        var relay = fixture.Policy.Candidates.Single(candidate => candidate.Id == "relay-a");
        fixture.Engine.RecordFailure(relay, fixture.Policy, fixture.Now);
        fixture.Engine.RecordFailure(relay, fixture.Policy, fixture.Now);
        fixture.Policy = fixture.Policy with
        {
            Probe = fixture.Policy.Probe with { MaxCandidates = 3 },
            Candidates = [.. fixture.Policy.Candidates, Candidate("new-relay", "198.51.100.40:51820", 80)],
        };
        fixture.OfflineCandidateId = "new-relay";
        Check(fixture.Connect().Success && fixture.Store.State?.CachedCandidateGrants?.Any(grant =>
            grant.CandidateId == "relay-a" && grant.Endpoint == RelayEndpoint) == true,
            "A partial prefetch discarded a valid lease merely because its route was temporarily quarantined.");
        fixture.Now = InitialTime.AddSeconds(31);
        fixture.Offline = true;
        Check(fixture.Connect().Success &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint, DirectEndpoint, RelayEndpoint]),
            "The preserved lease could not recover offline after quarantine elapsed.");
    }

    private static Fixture CachedFixture() => new(null, "tunnel_no_handshake", null) { CacheableGrants = true };

    private static NativeClientPreferences ColdPreferences => NativeClientPreferences.Default with
    {
        SmartRoutingEnabled = false,
        AntiLeakEnabled = false,
    };

    private static void ColdAutomaticAppReconnectUsesPrefetchedAuthorityOffline()
    {
        var fixture = CachedFixture();
        Check(fixture.Connect().Success, "Cold App fixture did not cache signed routes online.");
        var profileRequests = fixture.Requests.Count;
        var catalogRequests = fixture.CatalogRequests;
        fixture.Offline = true;
        var product = new VpnProductParityService();
        var response = product.ConnectAsync(fixture.NewCoordinator(), ColdPreferences,
            CancellationToken.None).GetAwaiter().GetResult();
        Check(response.Success && fixture.CatalogRequests == catalogRequests + 1 &&
            fixture.Requests.Count == profileRequests &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint, RelayEndpoint]) &&
            !fixture.Vpn.AntiLeak.Last(),
            "A cold automatic App required the server catalog instead of using protected signed routes offline.");
    }

    private static void ColdAutomaticAppNeverFallsBackAfterAnAuthenticationFailure()
    {
        var fixture = CachedFixture();
        fixture.Connect();
        fixture.CatalogError = new VexApiException(HttpStatusCode.Unauthorized, "auth_required");
        var product = new VpnProductParityService();
        ExpectFlow("sign_in_required", () => product.ConnectAsync(fixture.NewCoordinator(), ColdPreferences,
            CancellationToken.None).GetAwaiter().GetResult());
        Check(fixture.Store.State is null && fixture.Vpn.Endpoints.Count == 1,
            "A cold automatic App converted a revoked session into an offline reconnect.");
    }

    private static void ColdAutomaticAppRejectsExpiredAndMismatchedAuthority()
    {
        foreach (var scope in new[] { "signed-expiry", "policy-expiry", "location", "routing", "user" })
        {
            var fixture = scope == "policy-expiry"
                ? new Fixture("tunnel_no_handshake", null) { CacheableGrants = true }
                : CachedFixture();
            if (scope == "policy-expiry")
            {
                fixture.Policy = fixture.Policy with { ExpiresAt = Timestamp(InitialTime.AddSeconds(30)) };
            }
            fixture.Connect();
            var admissionCount = fixture.Vpn.Endpoints.Count;
            var state = fixture.Store.State!;
            var preferences = ColdPreferences;
            switch (scope)
            {
                case "signed-expiry":
                    fixture.Now = InitialTime.AddMinutes(11);
                    break;
                case "policy-expiry":
                    fixture.Now = InitialTime.AddMinutes(1);
                    break;
                case "location":
                    fixture.Store.Save(state with { LocationId = "de-1" });
                    break;
                case "routing":
                    preferences = preferences with { SmartRoutingEnabled = true };
                    break;
                default:
                    fixture.Store.Save(state with
                    {
                        Session = state.Session with { User = state.Session.User with { Id = "another-user" } },
                    });
                    break;
            }
            fixture.Offline = true;
            try
            {
                new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), preferences,
                    CancellationToken.None).GetAwaiter().GetResult();
            }
            catch (HttpRequestException)
            {
                Check(fixture.Vpn.Endpoints.Count == admissionCount,
                    "Cold catalog fallback admitted stale " + scope + " authority.");
                continue;
            }
            throw new InvalidOperationException("Cold catalog fallback accepted stale " + scope + " authority.");
        }
    }

    private static void ColdAppPreservesManualSelectionAndCallerCancellation()
    {
        var fixture = CachedFixture();
        fixture.Connect();
        fixture.Offline = true;
        try
        {
            new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), ColdPreferences with
            {
                AutoServerEnabled = false,
                SelectedLocationId = "de-1",
            }, CancellationToken.None).GetAwaiter().GetResult();
            throw new InvalidOperationException("Offline manual selection silently reconnected to the previous exit.");
        }
        catch (HttpRequestException) { }
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        try
        {
            new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), ColdPreferences,
                cancellation.Token).GetAwaiter().GetResult();
            throw new InvalidOperationException("Caller cancellation triggered cached reconnect.");
        }
        catch (OperationCanceledException) { }
        Check(fixture.Vpn.Endpoints.Count == 1, "Manual failure or cancellation reached the tunnel service.");
    }

    private static void ColdAppKeepsCanonicalDirectCacheUsableAfterPolicyExpiry()
    {
        var fixture = new Fixture(null, null)
        {
            CacheableGrants = true,
            GrantLifetimeForCandidate = _ => TimeSpan.FromHours(24),
        };
        fixture.Policy = fixture.Policy with { ExpiresAt = Timestamp(InitialTime.AddSeconds(30)) };
        fixture.Connect();
        fixture.Now = InitialTime.AddMinutes(1);
        fixture.Offline = true;
        Check(new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), ColdPreferences,
            CancellationToken.None).GetAwaiter().GetResult().Success &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, DirectEndpoint]),
            "Expiry of advisory routing invalidated an independently authorized 24-hour canonical direct profile.");
    }

    private static void ColdAppSkipsExpiredPrimaryAuthorityForALiveSignedRelay()
    {
        var fixture = new Fixture(null, null)
        {
            CacheableGrants = true,
            GrantLifetimeForCandidate = candidate => candidate is null
                ? TimeSpan.FromSeconds(30)
                : TimeSpan.FromMinutes(10),
        };
        fixture.Connect();
        var issuedCount = fixture.IssuedGrants.Count;
        fixture.Now = InitialTime.AddMinutes(1);
        fixture.Offline = true;
        Check(new VpnProductParityService().ConnectAsync(fixture.NewCoordinator(), ColdPreferences,
            CancellationToken.None).GetAwaiter().GetResult().Success &&
            fixture.Vpn.Endpoints.SequenceEqual([DirectEndpoint, RelayEndpoint]) &&
            fixture.IssuedGrants.Count == issuedCount,
            "A cold App executed an expired primary grant or fetched new authority instead of its live signed relay.");
    }

    private static void ExpectOfflineRecoveryFailure(Fixture fixture)
    {
        try
        {
            var response = fixture.Connect();
            Check(!response.Success, "Invalid candidate authority connected during an outage.");
        }
        catch (HttpRequestException) { }
    }

    private static VexEntitlement PaidUntil(DateTimeOffset expiry) =>
        new(true, "pro_monthly", "Pro", "active", "Pro", "Pro", "Paid", "active", "pro", Timestamp(expiry), null, true);

    private static ResilienceConnectionCandidate Candidate(string id, string endpoint, int priority) =>
        new(id, "device-1", "amneziawg", "fi-1", "fi-exit-node", endpoint, 100,
            Timestamp(InitialTime.AddHours(1)), id, id == "direct" ? "direct" : "relay", id + "-entry", id + "-domain", priority);

    private static ResiliencePolicy Policy(int maximum, params ResilienceConnectionCandidate[] candidates) =>
        new("policy-1", Timestamp(InitialTime), Timestamp(InitialTime.AddHours(1)), new("unsigned"),
            new(8000, maximum, [], FailureThreshold: 10), candidates);

    private static string Timestamp(DateTimeOffset value) => value.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",
        System.Globalization.CultureInfo.InvariantCulture);

    private static void ExpectFlow(string code, Action action)
    {
        try { action(); }
        catch (NativeClientFlowException error) when (error.Code == code) { return; }
        throw new InvalidOperationException("Expected flow error " + code);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    private sealed record ProfileRequest(string LocationId, string RoutingMode, string? CandidateId, int? KnownVersion);

    private sealed class Fixture
    {
        public DateTimeOffset Now { get; set; } = InitialTime;
        public bool Offline { get; set; }
        public bool CacheableGrants { get; init; }
        public Func<string?, TimeSpan>? GrantLifetimeForCandidate { get; init; }
        public bool HasHeaderProtectionKey { get; init; } = true;
        public ResiliencePolicy Policy { get; set; } = ClientSignedCandidateTests.Policy(2,
            Candidate("direct", DirectEndpoint, 100), Candidate("relay-a", RelayEndpoint, 90));
        public VexEntitlement Entitlement { get; set; } = PaidUntil(InitialTime.AddDays(30));
        public VexApiException? CandidateError { get; set; }
        public Exception? CatalogError { get; set; }
        public int CatalogRequests { get; private set; }
        public string? OfflineCandidateId { get; set; }
        public Func<string, string>? CandidateGrantEndpoint { get; set; }
        public MemoryClientStateStore Store { get; } = new();
        public MemoryRouteStore RouteStore { get; } = new();
        public GrantAwareVpnClient Vpn { get; }
        public DynamicRouteEngine Engine { get; }
        public NativeClientCoordinator Coordinator { get; }
        public INativeClientApi Api { get; }
        public List<ProfileRequest> Requests { get; } = [];
        public List<ManagedVpnProfileAuthorization> IssuedGrants { get; } = [];

        public Fixture(params string?[] outcomes)
        {
            Vpn = new(outcomes);
            var underlying = new FakeNativeClientApi
            {
                Locations = [new("fi-1", "Helsinki", "available", 1), new("de-1", "Frankfurt", "available", 1)],
            };
            var (api, proxy) = NativeApiProxy.Wrap(underlying);
            Api = api;
            proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = args =>
            {
                CatalogRequests++;
                if (CatalogError is not null) { throw CatalogError; }
                if (Offline) { throw new HttpRequestException("Server catalog offline."); }
                return proxy.CallUnderlying(nameof(INativeClientApi.GetLocationsAsync), args);
            };
            proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = args =>
                CatalogError is VexApiException { StatusCode: HttpStatusCode.Unauthorized }
                    ? throw new VexApiException(HttpStatusCode.Unauthorized, "auth_required")
                    : proxy.CallUnderlying(nameof(INativeClientApi.RefreshSessionAsync), args);
            proxy.Overrides[nameof(INativeClientApi.GetBillingEntitlementAsync)] = _ =>
                Offline ? throw new HttpRequestException("Control plane offline.") : Task.FromResult(Entitlement);
            proxy.Overrides[nameof(INativeClientApi.GetResiliencePolicyAsync)] = _ =>
                Offline ? throw new HttpRequestException("Control plane offline.") : Task.FromResult<ResiliencePolicy?>(Policy);
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnProfileAsync)] = args => Profile(args, false);
            proxy.Overrides[nameof(INativeClientApi.GetManagedVpnCandidateProfileAsync)] = args => Profile(args, true);
            Engine = new(RouteStore);
            Coordinator = new(api, Store, Vpn, "1.0.0", () => Now, Engine);
            Coordinator.SignInAndProvisionAsync("user@example.com", "password", CancellationToken.None).GetAwaiter().GetResult();
        }

        public VpnServiceResponse Connect(bool antiLeak = true, bool automatic = false) =>
            Coordinator.ConnectWithRecoveryAsync("fi-1", "full", antiLeak, automatic,
                CancellationToken.None).GetAwaiter().GetResult();

        public NativeClientCoordinator NewCoordinator() =>
            new(Api, Store, Vpn, "1.0.0", () => Now, new DynamicRouteEngine(RouteStore));

        private Task<ManagedVpnProfile> Profile(object?[] args, bool candidateRequest)
        {
            var location = (string)args[2]!;
            var routing = (string)args[3]!;
            var candidateId = candidateRequest ? (string)args[5]! : null;
            var knownVersion = candidateRequest ? null : (int?)args[5];
            Requests.Add(new(location, routing, candidateId, knownVersion));
            if (Offline) { throw new HttpRequestException("Control plane offline."); }
            if (candidateId is not null && candidateId == OfflineCandidateId)
            {
                throw new HttpRequestException("Candidate profile unavailable.");
            }
            if (candidateRequest && CandidateError is not null) { throw CandidateError; }
            var endpoint = candidateId is null
                ? location == "fi-1" ? DirectEndpoint : "198.51.100.30:51820"
                : CandidateGrantEndpoint?.Invoke(candidateId) ?? Policy.Candidates.Single(candidate => candidate.Id == candidateId).Endpoint;
            var version = IssuedGrants.Count + 1;
            var payload = new Dictionary<string, object?>
            {
                ["profile_version"] = version,
                ["user_id"] = "user-1",
                ["device_id"] = (string)args[1]!,
                ["assigned_location_id"] = location,
                ["requested_location_id"] = location,
                ["routing_mode"] = routing,
                ["bypass_region"] = args[4] ?? string.Empty,
                ["tunnel"] = new
                {
                    protocol = "amneziawg", endpoint, preshared_key = "SignedPsk",
                    amnezia = new { header_protection_key = HasHeaderProtectionKey ? "Awg3HeaderKey" : string.Empty },
                },
            };
            if (CacheableGrants)
            {
                payload["issued_at"] = Timestamp(Now);
                payload["expires_at"] = Timestamp(Now.Add(GrantLifetimeForCandidate?.Invoke(candidateId) ?? TimeSpan.FromMinutes(10)));
            }
            var authorization = new ManagedVpnProfileAuthorization("profile-key-1", "ECDSA_P256_SHA256_DER",
                Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload))), "c2lnbmF0dXJl");
            IssuedGrants.Add(authorization);
            return Task.FromResult(new ManagedVpnProfile(version, (string)args[1]!, false, false, authorization));
        }
    }

    private sealed class MemoryRouteStore : IDynamicRouteStore
    {
        private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);
        public string? Read(string key) => values.GetValueOrDefault(key);
        public void Write(string key, string value) => values[key] = value;
    }

    private sealed class GrantAwareVpnClient(params string?[] outcomes) : IVpnControlClient
    {
        private VpnConnectionSnapshot snapshot = VpnConnectionSnapshot.Disconnected();
        public List<string> Endpoints { get; } = [];
        public List<bool> AntiLeak { get; } = [];
        public List<VpnProfileAuthorization> Authorizations { get; } = [];

        public Task<VpnServiceResponse> GetStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new VpnServiceResponse("status", true, snapshot, null));

        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization,
            string privateKey, CancellationToken cancellationToken) =>
            ConnectAsync(authorization, privateKey, true, cancellationToken);

        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization,
            string privateKey, bool antiLeakEnabled, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var payload = JsonDocument.Parse(Convert.FromBase64String(authorization.PayloadBase64));
            var root = payload.RootElement;
            var endpoint = root.GetProperty("tunnel").GetProperty("endpoint").GetString()!;
            var error = Endpoints.Count < outcomes.Length ? outcomes[Endpoints.Count] : null;
            Endpoints.Add(endpoint);
            AntiLeak.Add(antiLeakEnabled);
            Authorizations.Add(authorization);
            snapshot = new(error is null ? VpnConnectionPhase.Connected : VpnConnectionPhase.Error,
                root.GetProperty("assigned_location_id").GetString(), Endpoints.Count, error);
            return Task.FromResult(new VpnServiceResponse("connect-" + Endpoints.Count, error is null, snapshot, error));
        }

        public Task<VpnServiceResponse> DisconnectAsync(CancellationToken cancellationToken)
        {
            snapshot = VpnConnectionSnapshot.Disconnected();
            return GetStatusAsync(cancellationToken);
        }
    }
}

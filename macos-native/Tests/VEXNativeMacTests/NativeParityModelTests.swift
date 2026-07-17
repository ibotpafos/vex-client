import XCTest
import CryptoKit
@testable import VEXNativeMac

final class NativeParityModelTests: XCTestCase {
    func testDeviceIdentityBuildsBackendRegistrationContract() throws {
        let key = P256.Signing.PrivateKey()
        let identity = try VEXDeviceIdentity(privateKeyRaw: key.rawRepresentation)
        let challenge = DeviceIdentityChallenge(id: "devchal_1", nonce: "nonce_1", purpose: "register", expiresAt: nil)

        let publicKey = identity.publicKeyJWK
        let payload = VEXDeviceIdentity.signaturePayload(
            challenge: challenge,
            installationId: "vexd_test",
            identityPublicKey: publicKey,
            wireGuardPublicKey: "wg_public"
        )
        let signature = try identity.signature(for: payload)
        let jwk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(publicKey.utf8)) as? [String: String])

        XCTAssertEqual(VEXDeviceIdentity.keyType, "p256_jwk")
        XCTAssertEqual(VEXDeviceIdentity.trustLevel, "software_secure_store")
        XCTAssertEqual(jwk["kty"], "EC")
        XCTAssertEqual(jwk["crv"], "P-256")
        XCTAssertFalse(jwk["x", default: ""].contains("="))
        XCTAssertFalse(jwk["y", default: ""].contains("="))
        XCTAssertFalse(signature.contains("="))
        XCTAssertTrue(payload.contains("vex-device-binding-v1\n"))

        let x = try XCTUnwrap(Data(base64URLEncoded: try XCTUnwrap(jwk["x"])))
        let y = try XCTUnwrap(Data(base64URLEncoded: try XCTUnwrap(jwk["y"])))
        let verificationKey = try P256.Signing.PublicKey(rawRepresentation: x + y)
        let signatureData = try XCTUnwrap(Data(base64URLEncoded: signature))
        let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)

        XCTAssertTrue(verificationKey.isValidSignature(ecdsaSignature, for: Data(payload.utf8)))
    }

    func testManagedProfileDecodesServerContract() throws {
        let data = """
        {
          "version": 12,
          "protocol": "amneziawg",
          "server": "de1.vexguard.app",
          "port": 443,
          "server_public_key": "server-key",
          "assigned_ipv4": "10.8.0.2/32",
          "allowed_ips": ["0.0.0.0/0"],
          "bypass_ranges": ["10.0.0.0/8"],
          "bypass_domains": ["example.ru"],
          "routing_policy_version": "2026.06.22.1",
          "amnezia": {"jc": 4, "h1": "abc"}
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ManagedVpnProfile.self, from: data)

        XCTAssertEqual(profile.version, 12)
        XCTAssertEqual(profile.protocol, "amneziawg")
        XCTAssertEqual(profile.server, "de1.vexguard.app")
        XCTAssertEqual(profile.port, 443)
        XCTAssertEqual(profile.amnezia?.jc, 4)
        XCTAssertEqual(profile.bypassDomains, ["example.ru"])
    }

    func testManagedProfileRequestsMacOSCompactRoutingPolicy() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let apiURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXAPIClient.swift")
        let api = try String(contentsOf: apiURL, encoding: .utf8)

        XCTAssertTrue(api.contains("URLQueryItem(name: \"platform\", value: \"macos\")"))
    }

    func testPreparedTunnelCacheRoundTrips() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test"}
        """.data(using: .utf8)!)
        let tunnel = PreparedTunnel(
            device: device,
            config: "[Interface]\\nPrivateKey = x\\n[Peer]\\nPublicKey = y\\n",
            locationId: "de",
            profileVersion: 7,
            routingMode: .allExceptRu,
            bypassRegion: "ru",
            bypassRangesCount: 1,
            bypassDomainsCount: 2,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        )

        let data = try JSONEncoder().encode(PreparedTunnelCacheRecord(tunnel: tunnel))
        let decoded = try JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: data)

        XCTAssertEqual(decoded.tunnel.device.id, "dev_1")
        XCTAssertEqual(decoded.tunnel.locationId, "de")
        XCTAssertEqual(decoded.tunnel.profileVersion, 7)
        XCTAssertEqual(decoded.tunnel.routingMode, .allExceptRu)
    }

    func testLegacyManagedSplitRouteCacheForcesProfileRefresh() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test"}
        """.data(using: .utf8)!)
        let cached = PreparedTunnelCacheRecord(tunnel: PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x

            [Peer]
            PublicKey = y
            AllowedIPs = 0.0.0.0/2, 64.0.0.0/4, 94.141.160.213/32, 128.0.0.0/1, ::/0
            """,
            locationId: "de",
            profileVersion: 8,
            routingMode: .allExceptRu,
            bypassRegion: "ru",
            bypassRangesCount: 1,
            bypassDomainsCount: 1,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        ))

        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "de", requestedRoutingMode: .allExceptRu))
        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "de", requestedRoutingMode: .fullTunnel))
    }

    func testCompactManagedProfileCacheDoesNotForceRefresh() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test"}
        """.data(using: .utf8)!)
        let cached = PreparedTunnelCacheRecord(tunnel: PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x

            [Peer]
            PublicKey = y
            AllowedIPs = 0.0.0.0/0, ::/0
            """,
            locationId: "de",
            profileVersion: 9,
            routingMode: .allExceptRu,
            bypassRegion: "ru",
            bypassRangesCount: 1,
            bypassDomainsCount: 1,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        ))

        XCTAssertFalse(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "de", requestedRoutingMode: .allExceptRu))
    }

    func testStaleManagedProfileCacheRequiresRefreshBeforeForegroundConnect() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test","node_id":"de-1"}
        """.data(using: .utf8)!)
        var cached = PreparedTunnelCacheRecord(tunnel: PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x

            [Peer]
            PublicKey = y
            AllowedIPs = 0.0.0.0/0, ::/0
            """,
            locationId: "de",
            profileVersion: 9,
            routingMode: .fullTunnel,
            bypassRegion: nil,
            bypassRangesCount: 0,
            bypassDomainsCount: 0,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        ))
        cached.fetchedAt = Date(timeIntervalSinceNow: -10 * 60)

        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "de", requestedRoutingMode: .fullTunnel))
        XCTAssertFalse(VPNProfileService.cachedProfileNeedsRefresh(
            cached,
            requestedLocationId: "de",
            requestedRoutingMode: .fullTunnel,
            allowStale: true
        ))
    }

    func testForegroundProfileResolutionDoesNotAcceptStaleCacheBeforeApi() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertFalse(profileService.contains("""
        requestedRoutingMode: routingMode,
                        allowStale: true
                   ) {
        """))
        XCTAssertTrue(profileService.contains("if error.isTimeout"))
    }

    func testMacOSHelperConfigDropsIPv6AllowedIPsWithoutIPv6Address() {
        let config = """
        [Interface]
        PrivateKey = x
        Address = 10.64.1.25/32
        DNS = 10.64.1.1

        [Peer]
        PublicKey = y
        Endpoint = de-1.vexguard.app:51820
        AllowedIPs = 0.0.0.0/0, ::/0, 2001:db8::/32
        """

        let helperConfig = VPNProfileService.sanitizedMacOSHelperConfig(config) { endpoint in
            endpoint == "de-1.vexguard.app:51820" ? "203.0.113.10:51820" : endpoint
        }

        XCTAssertTrue(helperConfig.contains("Endpoint = 203.0.113.10:51820"))
        XCTAssertTrue(helperConfig.contains("AllowedIPs = 0.0.0.0/0"))
        XCTAssertFalse(helperConfig.contains("::/0"))
        XCTAssertFalse(helperConfig.contains("2001:db8::/32"))
    }

    func testMacOSHelperConfigKeepsIPv6AllowedIPsWhenIPv6AddressExists() {
        let config = """
        [Interface]
        PrivateKey = x
        Address = 10.64.1.25/32, fd00::25/128

        [Peer]
        PublicKey = y
        Endpoint = 203.0.113.10:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        """

        let helperConfig = VPNProfileService.sanitizedMacOSHelperConfig(config)

        XCTAssertTrue(helperConfig.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
    }

    func testAppStateUsesCachedProfileForConnectAndWarmsProfilesInBackground() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("private var profileWarmupTask: Task<Void, Never>?"))
        XCTAssertTrue(appState.contains("scheduleProfileWarmup()"))
        XCTAssertTrue(appState.contains("forceRefresh: false\n            )\n            try ensureConnectStillDesired"))
        XCTAssertTrue(appState.contains("forceRefresh: true,\n                    writeHelperConfig: false\n                )\n            } catch is CancellationError"))
    }

    func testAppStateRestoresActiveTunnelWhenHelperIsAlreadyConnectedOnLaunch() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let app = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(app.contains("await appState.start(helperStatus: helper.status)"))
        XCTAssertTrue(appState.contains("func start(helperStatus: VpnStatus? = nil) async"))
        XCTAssertTrue(appState.contains("await restoreActiveTunnelIfHelperIsConnected(helperStatus)"))
        XCTAssertTrue(appState.contains("guard let helperStatus, helperStatus.isUsableConnectedStatus, activeTunnel == nil else { return }"))
        XCTAssertTrue(appState.contains("await prepareSelectedProfile(forceRefresh: false)"))
        XCTAssertTrue(appState.contains("if let activeTunnel, tunnel(activeTunnel, matches: helperStatus)"))
        XCTAssertTrue(appState.contains("VPN уже активен на другом профиле"))
    }

    func testManualServerSelectionIsNotSilentlyReplacedByFailover() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("guard allowsAutomaticFailover, assessment.canFailover"))
        XCTAssertTrue(appState.contains("let failoverLocation = allowsAutomaticFailover ? bestFailoverLocation"))
        XCTAssertTrue(appState.contains("private var allowsAutomaticFailover: Bool"))
        XCTAssertTrue(appState.contains("autoServerEnabled && serverSelectionMode == \"auto\""))
        XCTAssertTrue(appState.contains("if selectedLocation == nil, serverSelectionMode != \"manual\""))
        XCTAssertFalse(appState.contains("await helper.connect(antiLeakEnabled: antiLeakEnabled)\n                selectedLocationId = previousLocationId"))
    }

    func testConnectedManualSelectionSwitchesWhenEndpointDoesNotMatch() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("if shouldSwitchConnectedTunnel(for: helper.status)"))
        XCTAssertTrue(appState.contains("private func tunnel(_ tunnel: PreparedTunnel, matches status: VpnStatus) -> Bool"))
        XCTAssertTrue(appState.contains("let candidates = [tunnel.configEndpoint, tunnel.endpoint].compactMap(normalizedEndpoint)"))
        XCTAssertTrue(appState.contains("return serverSelectionMode == \"manual\""))
    }

    func testProfileWarmupDoesNotOverwriteHelperConfig() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertTrue(profileService.contains("writeHelperConfig: Bool = true"))
        XCTAssertTrue(appState.contains("writeHelperConfig: false"))
        XCTAssertTrue(appState.contains("func scheduleProfileWarmup()"))
    }

    func testManagedProfileCacheRefreshesWhenLocationOrNodeIsMixed() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test","node_id":"fi-1"}
        """.data(using: .utf8)!)
        let cached = PreparedTunnelCacheRecord(tunnel: PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x

            [Peer]
            PublicKey = y
            AllowedIPs = 0.0.0.0/0, ::/0
            """,
            locationId: "de",
            profileVersion: 10,
            routingMode: .allExceptRu,
            bypassRegion: "ru",
            bypassRangesCount: 1,
            bypassDomainsCount: 1,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        ))

        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "de", requestedRoutingMode: .allExceptRu))
        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedLocationId: "fi", requestedRoutingMode: .allExceptRu))
    }

    func testFullTunnelProfileProvisioningFailureFallsBackToSmartRoute() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let apiURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXAPIClient.swift")
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)
        let api = try String(contentsOf: apiURL, encoding: .utf8)

        XCTAssertTrue(api.contains("isProfileProvisioningUnavailable"))
        XCTAssertTrue(api.contains("add-peer"))
        XCTAssertTrue(profileService.contains("routingMode == .fullTunnel, error.isProfileProvisioningUnavailable"))
        XCTAssertTrue(profileService.contains("effectiveRoutingMode = .allExceptRu"))
        XCTAssertTrue(profileService.contains("bypassRegion: effectiveBypassRegion"))
        XCTAssertTrue(profileService.contains("copy.nodeId = managedProfileNodeId(profile) ?? nodeIdForLocation(locationId)"))
    }

    func testNativeDeviceMetadataSyncsExistingDeviceVersion() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let apiURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXAPIClient.swift")
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)
        let api = try String(contentsOf: apiURL, encoding: .utf8)

        XCTAssertTrue(profileService.contains("syncNativeDeviceMetadataIfNeeded"))
        XCTAssertTrue(profileService.contains("nativeDeviceMetadataNeedsSync"))
        XCTAssertTrue(profileService.contains("normalized(device.appVersion) != VEXAppInfo.version"))
        XCTAssertTrue(api.contains("native-register-\\(externalDeviceId)-\\(VEXAppInfo.version)-\\(VEXAppInfo.buildNumber)"))
    }

    func testSessionRefreshIsSingleFlightAndDoesNotClearNewerSession() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("private var sessionRefreshTask: (accessToken: String, task: Task<Result<AuthSession, Error>, Never>)?"))
        XCTAssertTrue(appState.contains("if let sessionRefreshTask"))
        XCTAssertTrue(appState.contains("refreshAccessToken: sessionRefreshTask.accessToken"))
        XCTAssertTrue(appState.contains("if session?.accessToken == refreshAccessToken"))
        XCTAssertTrue(appState.contains("return session?.accessToken"))
    }

    func testEntitlementAllowsEitherActiveOrVpnAccessLikeTauriClient() {
        XCTAssertTrue(Entitlement(active: true, vpnAccess: false).hasPaidAccess)
        XCTAssertTrue(Entitlement(active: false, vpnAccess: true).hasPaidAccess)
        XCTAssertFalse(Entitlement(active: false, vpnAccess: false).hasPaidAccess)
    }

    func testBillingSummaryBuildsFallbackPlansAndCurrentPlan() {
        let entitlement = Entitlement(
            active: false,
            planId: "pro_monthly",
            displayName: "Pro",
            accountStatus: nil,
            subscriptionTitle: nil,
            subscriptionSubtitle: nil,
            remainingText: "10 дней",
            status: "active",
            tier: "pro",
            currentPeriodEnd: "2026-07-30T00:00:00Z",
            effectiveExpiresAt: nil,
            vpnAccess: true
        )

        let summary = BillingService().buildSummary(plans: [], entitlement: entitlement)

        XCTAssertEqual(summary.entitlementStatus, .active)
        XCTAssertEqual(summary.currentPlan?.id, "pro_monthly")
        XCTAssertEqual(summary.currentPlan?.action, "Текущий")
        XCTAssertEqual(summary.plans.count, 3)
    }

    func testBillingSummaryCacheRoundTripsPerUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vex-billing-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = BillingSummaryCache(store: AppSensitiveFileStore(directoryURL: directory))
        let summary = BillingService().buildSummary(
            plans: [],
            entitlement: Entitlement(active: true, planId: "pro_monthly", vpnAccess: true)
        )

        cache.save(userId: "user_1", summary: summary)
        let loaded = try XCTUnwrap(cache.load(userId: "user_1"))

        XCTAssertEqual(loaded.entitlementStatus, .active)
        XCTAssertEqual(loaded.currentPlan?.id, "pro_monthly")
        XCTAssertNil(cache.load(userId: "user_2"))
    }

    func testBillingPaymentDecodesCustomerHistoryContract() throws {
        let data = """
        {
          "id": "pay_1",
          "subscription_id": "sub_1",
          "checkout_session_id": "bcs_1",
          "plan_id": "pro_monthly",
          "provider": "platega",
          "amount_minor": 49900,
          "currency": "RUB",
          "method": "card",
          "status": "paid",
          "receipt_url": "https://pay.example.test/receipt",
          "paid_at": "2026-06-30T12:00:00Z",
          "created_at": "2026-06-30T11:59:00Z"
        }
        """.data(using: .utf8)!

        let payment = try JSONDecoder().decode(BillingPayment.self, from: data)

        XCTAssertEqual(payment.id, "pay_1")
        XCTAssertEqual(payment.planId, "pro_monthly")
        XCTAssertEqual(payment.amountMinor, 49900)
        XCTAssertEqual(payment.receiptUrl, "https://pay.example.test/receipt")
    }

    func testClientDiagnosticsEncodesBackendSnakeCaseContract() throws {
        let report = ClientDiagnosticsReport(
            deviceId: "dev_1",
            reason: "vpn_connect_failed",
            status: "error",
            vpnState: "disconnected",
            endpoint: "de1.vexguard.app:443",
            latencyAverageMs: 42,
            rxBytes: 10,
            txBytes: 20,
            samples: ["selected_location_id": "de"]
        )

        let dictionary = try report.dictionary()

        XCTAssertEqual(dictionary["device_id"] as? String, "dev_1")
        XCTAssertEqual(dictionary["app_version"] as? String, "\(VEXAppInfo.version)+\(VEXAppInfo.buildNumber)")
        XCTAssertEqual(dictionary["vpn_state"] as? String, "disconnected")
        XCTAssertEqual(dictionary["latency_avg_ms"] as? Double, 42)
        XCTAssertEqual(dictionary["rx_bytes"] as? Int, 10)
        XCTAssertEqual((dictionary["samples"] as? [String: String])?["selected_location_id"], "de")
    }

    func testSupportSocketEnvelopeDecodesSnapshot() throws {
        let data = """
        {
          "type": "support.snapshot",
          "tickets": [{
            "id": "ticket_1",
            "subject": "VPN",
            "message": "Need help",
            "status": "open",
            "source": "macos-native",
            "created_at": "2026-06-30T00:00:00Z",
            "updated_at": "2026-06-30T00:00:00Z"
          }]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SupportSocketEnvelope.self, from: data)

        XCTAssertEqual(envelope.type, "support.snapshot")
        XCTAssertEqual(envelope.tickets?.first?.source, "macos-native")
    }

    func testUpdateCheckDecodesChecksumAndSignatureMetadata() throws {
        let data = """
        {
          "updateAvailable": true,
          "required": false,
          "latestVersion": "0.1.36",
          "latestBuild": 36,
          "minSupportedBuild": 1,
          "downloadUrl": "/downloads/VEX.dmg",
          "checksumSha256": "abc",
          "signatureUrl": "/downloads/VEX.dmg.sig",
          "channel": "stable"
        }
        """.data(using: .utf8)!

        let update = try JSONDecoder().decode(AppUpdateCheckResult.self, from: data)

        XCTAssertEqual(update.latestVersion, "0.1.36")
        XCTAssertEqual(update.checksumSha256, "abc")
        XCTAssertEqual(update.signatureUrl, "/downloads/VEX.dmg.sig")
    }

    func testRemoteConfigDecodesSettingsParityContract() throws {
        let data = """
        {
          "version": "2026.06.30",
          "platform": "macos",
          "channel": "stable",
          "coreVersion": "0.1.0",
          "configSchemaVersion": 1,
          "routingPolicyVersion": "2026.06.22.1",
          "featureFlags": {"smartRouting": true},
          "incidentBanner": "Service status text"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppRemoteConfig.self, from: data)

        XCTAssertEqual(config.platform, "macos")
        XCTAssertEqual(config.routingPolicyVersion, "2026.06.22.1")
        XCTAssertEqual(config.featureFlags?["smartRouting"], true)
        XCTAssertEqual(config.incidentBanner, "Service status text")
    }

    func testAutopilotClassifiesKeyProfileAndServerIssues() {
        let service = VpnAutopilotService()

        let keyAssessment = service.assess(error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "wireguard key rotation required"]))
        XCTAssertEqual(keyAssessment.cause, .keyOrProfile)
        XCTAssertTrue(keyAssessment.canFailover)

        let handshakeAssessment = service.assess(error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no_handshake: tunnel route is active but peer did not answer"]))
        XCTAssertEqual(handshakeAssessment.cause, .keyOrProfile)
        XCTAssertTrue(handshakeAssessment.canFailover)

        let serverAssessment = service.assess(healthReasons: [.deviceUsageDegraded, .staleLocalHandshake])
        XCTAssertEqual(serverAssessment.cause, .server)
        XCTAssertTrue(serverAssessment.canFailover)
        XCTAssertEqual(serverAssessment.samples["health_reasons"], "device_usage_degraded,stale_local_handshake")
    }

    func testAutopilotBuildsEndpointFallbackAttempts() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test","endpoint":"de1.vexguard.app:8443"}
        """.data(using: .utf8)!)
        let tunnel = PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x
            [Peer]
            PublicKey = y
            Endpoint = de1.vexguard.app:8443

            """,
            locationId: "de",
            profileVersion: 7,
            routingMode: .allExceptRu,
            bypassRegion: "ru",
            bypassRangesCount: 1,
            bypassDomainsCount: 2,
            routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
            rotationRequired: false
        )

        let attempts = VpnAutopilotService().fallbackTunnels(for: tunnel)

        XCTAssertEqual(attempts.map(\.endpoint), [
            "de1.vexguard.app:8443",
            "de1.vexguard.app:443",
            "de1.vexguard.app:51820",
        ])
        XCTAssertTrue(attempts[1].config.contains("Endpoint = de1.vexguard.app:443"))
    }

    func testNativeHelperStartDoesNotRequireAdminPassword() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let helperInstallerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let helperInstaller = try String(contentsOf: helperInstallerURL, encoding: .utf8)

        XCTAssertTrue(helperInstaller.contains("func ensureReady(allowAdminInstall: Bool = true)"))
        XCTAssertTrue(helperModel.contains("try await installer.ensureReady(allowAdminInstall: false)"))
        XCTAssertTrue(helperModel.contains("try await installer.ensureReady(allowAdminInstall: true)"))
        XCTAssertTrue(helperInstaller.contains("adminInstallRequired"))
    }

    func testNativeHelperReadyRequiresCurrentFilesEvenWhenSocketResponds() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperInstallerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let helperInstaller = try String(contentsOf: helperInstallerURL, encoding: .utf8)

        XCTAssertTrue(helperInstaller.contains("let currentFilesInstalled = filesAreCurrent"))
        XCTAssertTrue(helperInstaller.contains("if socketIsConnectable && currentFilesInstalled"))
        XCTAssertTrue(helperInstaller.contains("resourceMatchesInstalled(\"vex-helper\")"))
        XCTAssertTrue(helperInstaller.contains("resourceMatchesInstalled(\"amneziawg-go\")"))
        XCTAssertTrue(helperInstaller.contains("resourceMatchesInstalled(\"awg\")"))
        XCTAssertTrue(helperInstaller.contains("resourceFile(\"helper-version\")"))
        XCTAssertTrue(helperInstaller.contains("trimmingCharacters(in: .whitespacesAndNewlines)"))
        XCTAssertTrue(helperInstaller.contains("plistValueIsTrue(\"RunAtLoad\", in: plist)"))
        XCTAssertTrue(helperInstaller.contains("plistValueIsTrue(\"KeepAlive\", in: plist)"))
        XCTAssertTrue(helperInstaller.contains("SHA256.hash"))
        XCTAssertFalse(helperInstaller.contains("if socketIsConnectable {\n            return\n        }"))
    }

    func testNativeHelperVersionUsesBundledResourceAcrossInstallPaths() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperVersionURL = packageRoot.appendingPathComponent("../src-tauri/resources/helper-version").standardizedFileURL
        let installerURL = packageRoot.appendingPathComponent("../src-tauri/resources/install-vex-vpn-helper.sh").standardizedFileURL
        let nativeInstallerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let buildScriptURL = packageRoot.appendingPathComponent("../scripts/build_native_macos_app.sh").standardizedFileURL
        let verifyScriptURL = packageRoot.appendingPathComponent("../scripts/verify_native_macos_runtime.sh").standardizedFileURL
        let tauriConfigURL = packageRoot.appendingPathComponent("../src-tauri/tauri.conf.json").standardizedFileURL

        let helperVersion = try String(contentsOf: helperVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installer = try String(contentsOf: installerURL, encoding: .utf8)
        let nativeInstaller = try String(contentsOf: nativeInstallerURL, encoding: .utf8)
        let buildScript = try String(contentsOf: buildScriptURL, encoding: .utf8)
        let verifyScript = try String(contentsOf: verifyScriptURL, encoding: .utf8)
        let tauriConfig = try String(contentsOf: tauriConfigURL, encoding: .utf8)

        XCTAssertEqual(helperVersion, "33")
        XCTAssertTrue(installer.contains("helper_version_file=\"$src_dir/helper-version\""))
        XCTAssertTrue(nativeInstaller.contains("resourceFile(\"helper-version\")"))
        XCTAssertTrue(buildScript.contains("helper-version"))
        XCTAssertTrue(verifyScript.contains("helper_version_from_bundle"))
        XCTAssertTrue(tauriConfig.contains("\"resources/helper-version\""))
        XCTAssertFalse(nativeInstaller.contains("private let helperVersion = \""))
    }

    func testSettingsShowStaleHelperAsInstallRequired() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settingsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSettingsView.swift")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(settings.contains("Требует установки"))
        XCTAssertTrue(settings.contains("\\(value) устарел"))
        XCTAssertTrue(settings.contains("helper.repairHelper()"))
        XCTAssertTrue(settings.contains("Установить актуальный системный helper."))
        XCTAssertFalse(settings.contains("Требует проверки"))
    }

    func testStaleHelperPrimaryActionsRunRepairInsteadOfVpnConnect() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let sidebarURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSidebar.swift")
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        let sidebar = try String(contentsOf: sidebarURL, encoding: .utf8)

        XCTAssertTrue(home.contains("requiresHelperInstall: helper.installRequiredMessage != nil"))
        XCTAssertTrue(home.contains("await helper.repairHelper()"))
        XCTAssertTrue(home.contains("return \"Установить\""))
        XCTAssertTrue(home.contains("return \"Helper требуется\""))
        XCTAssertTrue(sidebar.contains("return \"Установить helper\""))
        XCTAssertTrue(sidebar.contains("await helper.repairHelper()"))
    }

    func testStableVpnHeroDestroysRepeatingAnimationView() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let home = try String(contentsOf: homeURL, encoding: .utf8)

        XCTAssertTrue(home.contains("if shouldAnimateHero {"))
        XCTAssertTrue(home.contains("AnimatedHeroLayers("))
        XCTAssertTrue(home.contains("StaticHeroLayers("))
        XCTAssertFalse(home.contains(".animation(shouldAnimateHero ? pulseAnimation : nil"))
        XCTAssertFalse(home.contains(".animation(shouldAnimateHero ? orbitAnimation : nil"))
    }

    func testNativeRuntimeVerifierIsReadOnlyAndChecksHelperTruth() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot.appendingPathComponent("../scripts/verify_native_macos_runtime.sh").standardizedFileURL
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("app_codesign=ok"))
        XCTAssertTrue(script.contains("root helper does not match bundled helper"))
        XCTAssertTrue(script.contains("root helper version does not match bundled helper version"))
        XCTAssertTrue(script.contains("helper_version_from_bundle"))
        XCTAssertTrue(script.contains("helper_install_action="))
        XCTAssertTrue(script.contains("route_iface="))
        XCTAssertTrue(script.contains("STRICT"))
        XCTAssertFalse(script.contains("up-no-antileak"))
        XCTAssertFalse(script.contains(" up "))
        XCTAssertFalse(script.contains(" down"))
    }

    func testNativeHelperInstallScriptUsesInstalledAppAndStrictVerifier() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot.appendingPathComponent("../scripts/install_native_macos_helper_from_app.sh").standardizedFileURL
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("/Applications/VEX Native.app"))
        XCTAssertTrue(script.contains("install-vex-vpn-helper.sh"))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("STRICT=1"))
        XCTAssertTrue(script.contains("verify_native_macos_runtime.sh"))
        XCTAssertFalse(script.contains("up-no-antileak"))
        XCTAssertFalse(script.contains(" down"))
    }

    func testNativeHelperInstallerClearsTransientAntiLeakState() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot.appendingPathComponent("../src-tauri/resources/install-vex-vpn-helper.sh").standardizedFileURL
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("antileak.state"))
        XCTAssertTrue(script.contains("antileak.active"))
        XCTAssertTrue(script.contains("operation.lock"))
        XCTAssertTrue(script.contains("utun.name"))
    }

    func testHelperRepairActionIsSeparateFromVpnConnect() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("func repairHelper() async"))
        XCTAssertTrue(helperModel.contains("installer.repairWithAdminPrivileges()"))
        XCTAssertTrue(helperModel.contains("Helper установлен."))
        XCTAssertTrue(helperModel.contains("var installRequiredMessage: String?"))
    }

    func testNativeConnectSkipsRedundantDisconnectAndWaitsForUsableStatus() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("shouldDisconnectBeforeConnect"))
        XCTAssertTrue(helperModel.contains("refreshConnectedStatusUntilStable"))
        XCTAssertTrue(helperModel.contains("status.isUsableConnectedStatus"))
        XCTAssertTrue(appState.contains("if helper.status.isUsableConnectedStatus"))
        XCTAssertTrue(appState.contains("guard helper.status.isUsableConnectedStatus else"))
        XCTAssertTrue(appState.contains("scheduleProfileWarmup()"))
        XCTAssertFalse(appState.contains("await prepareSelectedProfile(forceRefresh: true)"))
        XCTAssertTrue(appState.contains("status: helper.status.isUsableConnectedStatus ? \"ok\" : \"info\""))
        XCTAssertTrue(appState.contains("guard autoRecoveryEnabled, helper.status.isUsableConnectedStatus, !helper.isBusy else { return }"))
        XCTAssertTrue(appState.contains("guard status.isUsableConnectedStatus else { return false }"))
        XCTAssertFalse(appState.contains("if helper.status.state == .connected {\n                return attempt"))
        XCTAssertFalse(appState.contains("status: helper.status.state == .connected ? \"ok\" : \"info\""))
    }

    func testNativeAppQuitDoesNotLeaveHelperOwnerAttached() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let app = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("func detachOwnerWatchdog(quiet: Bool = false) async"))
        XCTAssertTrue(helperModel.contains("await detachOwnerWatchdog(quiet: true)\n                    message = successMessage"))
        XCTAssertTrue(app.contains("sender.reply(toApplicationShouldTerminate: true)"))
        XCTAssertTrue(app.contains("return .terminateLater"))
    }

    func testNativeHelperPreservesExistingMacOSVpnServicesDuringConnect() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperURL = packageRoot.appendingPathComponent("../src-tauri/src/bin/helper/main.rs").standardizedFileURL
        let helper = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helper.contains("preserving foreign default route"))
        XCTAssertTrue(helper.contains("public_default_route_target()"))
        XCTAssertTrue(helper.contains("add_host_route_to_target(endpoint_host(&resolved_endpoint), target, log)"))
        XCTAssertTrue(helper.contains("arm_route_watchdog()"))
        XCTAssertTrue(helper.contains("load_protected_public_hosts()"))
        XCTAssertTrue(helper.contains("add_protected_public_host_routes_to_target(target, log)"))
        XCTAssertFalse(helper.contains("\"--nc\", \"stop\""))
        XCTAssertFalse(helper.contains("release_foreign_default_tunnels"))
    }

    func testNativeHelperSocketRemainsAccessibleToAppUser() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperURL = packageRoot.appendingPathComponent("../src-tauri/src/bin/helper/main.rs").standardizedFileURL
        let helper = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helper.contains("\"_windowserver\""))
        XCTAssertTrue(helper.contains("args([\":staff\", socket_path])"))
        XCTAssertTrue(helper.contains("permissions.set_mode(0o660)"))
    }

    func testFailedConnectAlwaysReleasesAntiLeak() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let firewallURL = packageRoot.appendingPathComponent("../src-tauri/src/bin/helper/firewall.rs").standardizedFileURL
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let firewall = try String(contentsOf: firewallURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("await client.silentDisconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(appState.contains("await helper.interruptWithDisconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(appState.contains("await helper.disconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(firewall.contains("LEGACY_ANTILEAK_STATE_FILE"))
        XCTAssertTrue(firewall.contains("remove_antileak_state_files()"))
    }

    func testAntiLeakAllowsProtectedControlPlaneHttps() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let firewallURL = packageRoot.appendingPathComponent("../src-tauri/src/bin/helper/firewall.rs").standardizedFileURL
        let firewall = try String(contentsOf: firewallURL, encoding: .utf8)

        XCTAssertTrue(firewall.contains("PROTECTED_PUBLIC_HOST_ROUTES"))
        XCTAssertTrue(firewall.contains("port = 443 keep state"))
        XCTAssertTrue(firewall.contains("port = 22 keep state"))
    }

    func testNativeSignInPanelCanUnlockStoredSession() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let signInPanelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/SignInPanel.swift")
        let signInPanel = try String(contentsOf: signInPanelURL, encoding: .utf8)

        XCTAssertTrue(signInPanel.contains("canUnlockStoredSession"))
        XCTAssertTrue(signInPanel.contains("unlockStoredSessionWithBiometrics"))
        XCTAssertTrue(signInPanel.contains("Открыть сохраненную сессию"))
    }

    func testBiometricLockedStartDoesNotForceBrowserLoginMessage() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("if let storedSession = sessionStore.loadSession()"))
        XCTAssertTrue(appState.contains("user = storedSession.user"))
        XCTAssertTrue(appState.contains("await loadUpdate()"))
        XCTAssertTrue(appState.contains("await loadRemoteConfig()"))
        XCTAssertFalse(appState.contains("session = nil\n            statusMessage = \"Подтвердите вход"))
    }

    @MainActor
    func testPKCECallbackRejectsDuplicateQueryItemsInsteadOfCrashing() throws {
        let suiteName = "vex-pkce-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("expected-state", forKey: "vex.auth.pkce.state")
        defaults.set("expected-verifier", forKey: "vex.auth.pkce.verifier")

        let service = PKCEAuthService(defaults: defaults)
        let duplicateState = try XCTUnwrap(URL(string: "vexguard://auth/callback?state=expected-state&state=other&code=abc"))
        let duplicateCode = try XCTUnwrap(URL(string: "vexguard://auth/callback?state=expected-state&code=abc&code=other"))

        XCTAssertThrowsError(try service.consumeVerifier(for: duplicateState))
        XCTAssertThrowsError(try service.code(from: duplicateCode))
    }

    func testSupportSocketOnlyMarksConnectedAfterOpenValidation() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let socketURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/SupportSocketClient.swift")
        let socket = try String(contentsOf: socketURL, encoding: .utf8)

        XCTAssertTrue(socket.contains("validateOpen(task)"))
        XCTAssertTrue(socket.contains("task.sendPing"))
        XCTAssertTrue(socket.contains("task?.cancel(with: .goingAway, reason: nil)"))
        XCTAssertFalse(socket.contains("task.resume()\n            isConnected = true"))
    }

    func testHelperConnectedStatusUsesTrafficReadyRouteAndUAPISocket() {
        XCTAssertTrue(VpnStatus(helperResponse: "state=connected iface=utun6 route_ok=true socket_exists=true rx=0 tx=128 latest_handshake=0\n").isUsableConnectedStatus)
        XCTAssertTrue(VpnStatus(helperResponse: "state=connected iface=utun6 route_ok=true socket_exists=true rx=1 tx=128 latest_handshake=0\n").isUsableConnectedStatus)
        XCTAssertTrue(VpnStatus(helperResponse: "state=connected iface=utun6 route_ok=true socket_exists=true rx=0 tx=128 latest_handshake=42\n").isUsableConnectedStatus)
        XCTAssertFalse(VpnStatus(helperResponse: "state=connected iface=utun6 route_ok=false socket_exists=true rx=0 tx=128 latest_handshake=0\n").isUsableConnectedStatus)
        XCTAssertFalse(VpnStatus(helperResponse: "state=disconnected iface= route_ok=false rx=0 tx=0 latest_handshake=0\n").isUsableConnectedStatus)
    }

    func testRouteConflictStatusExplainsMissingTraffic() {
        let status = VpnStatus(helperResponse: "state=error iface=utun7 route_ok=false route_iface=utun6 socket_exists=true rx=92 tx=11264 latest_handshake=0\n")

        XCTAssertEqual(status.state, .disconnected)
        XCTAssertTrue(status.hasRouteConflict)
        XCTAssertTrue(status.hasIPv4RouteConflict)
        XCTAssertEqual(
            status.routeConflictMessage,
            "Другой VPN удерживает системный маршрут. Трафик через VEX не идет."
        )
    }

    func testIPv6RouteConflictKeepsIPv4TunnelUsableButExplainsSlowTraffic() {
        let status = VpnStatus(helperResponse: "state=connected iface=utun6 route_ok=true route_iface=utun6 ipv6_route_ok=false ipv6_route_iface=utun0 socket_exists=true rx=92 tx=11264 latest_handshake=0\n")

        XCTAssertTrue(status.isUsableConnectedStatus)
        XCTAssertTrue(status.hasIPv6RouteConflict)
        XCTAssertEqual(
            status.routeConflictMessage,
            "IPv6 удерживает другой VPN. VEX ведет IPv4-трафик, часть сайтов может открываться медленно."
        )
    }

    func testUserFacingStatusHidesTechnicalNoise() {
        XCTAssertNil(VEXUserFacingText.status("Status refreshed."))
        XCTAssertNil(VEXUserFacingText.status("cancelled"))
        XCTAssertEqual(
            VEXUserFacingText.status("The operation couldn’t be completed. Socket is not connected"),
            "Обновляем состояние подключения..."
        )
        XCTAssertEqual(
            VEXUserFacingText.status("Command failed: could not connect to helper socket"),
            "Helper запускается..."
        )
        XCTAssertEqual(
            VEXUserFacingText.status("HTTP 404: not found"),
            "Сервис временно недоступен."
        )
        XCTAssertEqual(
            VEXUserFacingText.status("HTTP 503: upstream unavailable"),
            VEXAPIError.technicalWorksMessage
        )
        XCTAssertEqual(
            VEXUserFacingText.status("Command failed: Другой VPN удерживает системный маршрут через utun6."),
            "Другой VPN удерживает системный маршрут. Трафик через VEX не идет."
        )
        XCTAssertEqual(
            VEXUserFacingText.status("AdminInstallRequired: helper требует установки"),
            "Helper требует установки."
        )
        XCTAssertEqual(
            VEXUserFacingText.status("Command failed: Установка helper отменена пользователем."),
            "Установка helper отменена."
        )
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        self.init(base64Encoded: base64)
    }
}

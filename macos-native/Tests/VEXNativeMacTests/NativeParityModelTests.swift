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

    @MainActor
    func testManagedProfilePreservesAWG3Contract() throws {
        let data = """
        {
          "amnezia_version": 3,
          "amnezia": {
            "jc": 4,
            "s1": 12,
            "s2": 12,
            "s3": 12,
            "s4": 12,
            "header_protection_key": "header-key",
            "content_padding_addition": "0",
            "rekey_after_time": "120-180",
            "rekey_timeout": "2-4",
            "reject_after_time": "180-240",
            "keepalive_timeout": "10-15",
            "max_handshake_attempts": "20-30"
          }
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ManagedVpnProfile.self, from: data)
        let config = VPNProfileService.amneziaConfig(profile.amnezia)

        XCTAssertEqual(profile.amneziaVersion, 3)
        XCTAssertTrue(config.contains("HeaderProtectionKey = header-key\n"))
        XCTAssertTrue(config.contains("ContentPaddingAddition = 0\n"))
        XCTAssertTrue(config.contains("RekeyAfterTime = 120-180\n"))
        XCTAssertTrue(config.contains("RekeyTimeout = 2-4\n"))
        XCTAssertTrue(config.contains("RejectAfterTime = 180-240\n"))
        XCTAssertTrue(config.contains("KeepaliveTimeout = 10-15\n"))
        XCTAssertTrue(config.contains("MaxHandshakeAttempts = 20-30\n"))
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
        XCTAssertTrue(appState.contains("forceRefresh: false,\n                prevalidatedEntitlement: entitlement\n            )\n            try ensureConnectStillDesired"))
        XCTAssertTrue(appState.contains("forceRefresh: false,\n                    writeHelperConfig: false\n                )\n            } catch is CancellationError"))
        XCTAssertFalse(appState.contains("forceRefresh: true,\n                    writeHelperConfig: false"))
    }

    func testConnectReusesValidatedEntitlementWithoutSecondFetch() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("prevalidatedEntitlement: entitlement"))
        XCTAssertTrue(profileService.contains("prevalidatedEntitlement: Entitlement? = nil"))
        XCTAssertTrue(profileService.contains("if let prevalidatedEntitlement {"))
        XCTAssertTrue(profileService.contains("entitlement = try await api.entitlement(accessToken: accessToken)"))
    }

    func testHelperConfigSanitizationAvoidsMainThreadDNS() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertTrue(profileService.contains("nonisolated private static func resolveConfigEndpoint"))
        XCTAssertTrue(profileService.contains("nonisolated private static func sanitizedHelperConfigOffMain"))
        XCTAssertTrue(profileService.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertFalse(profileService.contains("endpointResolver: resolvedConfigEndpoint"), "DNS must not run on the main actor")
    }

    func testDNSResolverCachesAndExpiresEntriesWithoutNetwork() {
        let host = "dns-cache-test-\(UUID().uuidString).invalid"
        let base = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNil(IPv4Resolver.cachedAddress(for: host, now: base))

        IPv4Resolver.store("203.0.113.10", for: host, now: base)
        XCTAssertEqual(IPv4Resolver.cachedAddress(for: host, now: base.addingTimeInterval(IPv4Resolver.cacheTTLSeconds - 1)), "203.0.113.10")

        XCTAssertNil(IPv4Resolver.cachedAddress(for: host, now: base.addingTimeInterval(IPv4Resolver.cacheTTLSeconds + 1)), "Expired DNS entries must be dropped")
    }

    func testHelperConfigWriteSkipsUnchangedContent() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cacheURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileCache.swift")
        let cache = try String(contentsOf: cacheURL, encoding: .utf8)

        XCTAssertTrue(cache.contains("current == config"), "Unchanged helper config must not be rewritten to disk")
        XCTAssertTrue(cache.contains("atomically: true"))
    }

    func testLastSuccessfulEndpointStoreRoundTripsPerLocation() throws {
        let suiteName = "test-last-endpoint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LastTunnelEndpointStore(defaults: defaults)

        XCTAssertNil(store.endpoint(for: "de"))

        store.save("de1.vexguard.app:443", locationId: "de")
        XCTAssertEqual(store.endpoint(for: "de"), "de1.vexguard.app:443")
        XCTAssertNil(store.endpoint(for: "fi"), "Endpoints must be scoped per location")

        store.save("", locationId: "fi")
        XCTAssertNil(store.endpoint(for: "fi"), "Empty endpoints must be rejected")
    }

    func testConnectFlowPersistsLastSuccessfulEndpointForFasterReconnects() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let autopilotURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VpnAutopilotService.swift")
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let autopilot = try String(contentsOf: autopilotURL, encoding: .utf8)
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("LastTunnelEndpointStore().save(endpoint, locationId: attempt.locationId)"))
        XCTAssertTrue(appState.contains("LastTunnelEndpointStore().save(endpoint, locationId: nextTunnel.locationId)"))
        XCTAssertTrue(profileService.contains("LastTunnelEndpointStore().endpoint(for: locationId)"))
        XCTAssertTrue(autopilot.contains("if let lastSuccessfulEndpoint = tunnel.lastSuccessfulEndpoint"), "Autopilot must try the known-good endpoint first")
    }

    func testVpnReportingNeverBlocksBusyStateOrSuccessFeedback() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        // Every report call must live inside a fire-and-forget task, never on
        // the connect/disconnect/switch operation path itself.
        XCTAssertTrue(appState.contains("Task { [api] in\n                await api.reportVpnConnect(accessToken: tunnelToken, tunnel: connectedTunnel)"))
        XCTAssertTrue(appState.contains("Task { [api] in\n                await api.reportVpnDisconnect(accessToken: token, tunnel: reportedTunnel, reason: reason)"))
        XCTAssertTrue(appState.contains("Task { [api] in\n                    await api.reportVpnDisconnect(accessToken: token, tunnel: previousTunnel, reason: \"server_switch\")"))
        XCTAssertTrue(appState.contains("// Reporting is fire-and-forget"))
    }

    func testBillingFetchesRunConcurrently() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertTrue(appState.contains("async let plansResult = api.billingPlans()"))
        XCTAssertTrue(appState.contains("async let entitlementResult = api.entitlement(accessToken: token)"))
        XCTAssertTrue(appState.contains("async let paymentsResult = api.billingPayments(accessToken: token, limit: 24)"))
        XCTAssertTrue(appState.contains("billingPayments = try await paymentsResult"), "Payments must reuse the concurrently started request")
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

    func testManagedProfileAdvertisesAWG3Capability() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let apiURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXAPIClient.swift")
        let api = try String(contentsOf: apiURL, encoding: .utf8)

        XCTAssertTrue(api.contains("URLQueryItem(name: \"awg_version\", value: \"3\")"))
        XCTAssertFalse(api.contains("awgVersion == 3"), "AWG3 must be unconditional, not a branch")
        XCTAssertFalse(api.contains("awgVersion: Int = 3"), "AWG version is fixed and must not be parameterized")
    }

    func testConnectFlowDoesNotFallBackToAWG2() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)

        XCTAssertFalse(appState.contains("AWG2"), "AWG2 fallback was removed; connect flow must be AWG3-only")
        XCTAssertFalse(appState.contains("awgVersion: 2"), "AWG2 profile requests must not exist")
    }

    func testLegacyAWG2CacheRecordsAreInvalidatedForAWG3() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test"}
        """.data(using: .utf8)!)

        func tunnel(awgVersion: Int) -> PreparedTunnel {
            PreparedTunnel(
                device: device,
                config: "[Interface]\nPrivateKey = x\n\n[Peer]\nPublicKey = y\nEndpoint = de1.vexguard.app:443\n",
                locationId: "de",
                profileVersion: 1,
                routingMode: .allExceptRu,
                bypassRegion: nil,
                bypassRangesCount: 0,
                bypassDomainsCount: 0,
                routingPolicyVersion: VEXAppInfo.routingPolicyVersion,
                rotationRequired: false,
                awgVersion: awgVersion
            )
        }

        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profileServiceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VPNProfileService.swift")
        let profileService = try String(contentsOf: profileServiceURL, encoding: .utf8)

        XCTAssertTrue(profileService.contains("nonisolated static let awgVersion = 3"))
        XCTAssertTrue(profileService.contains("(cached.awgVersion ?? 2) != awgVersion"))
        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(
            PreparedTunnelCacheRecord(tunnel: tunnel(awgVersion: 2)),
            requestedLocationId: "de",
            requestedRoutingMode: .allExceptRu,
            allowStale: true
        ))
        XCTAssertFalse(VPNProfileService.cachedProfileNeedsRefresh(
            PreparedTunnelCacheRecord(tunnel: tunnel(awgVersion: 3)),
            requestedLocationId: "de",
            requestedRoutingMode: .allExceptRu,
            allowStale: true
        ))
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

    func testEntitlementAllowsEitherActiveOrVpnAccessLikeLegacyDesktopClient() {
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
        XCTAssertEqual(summary.currentPlan?.action, "Продлить")
        XCTAssertEqual(summary.currentPlan?.disabled, false)
        XCTAssertEqual(summary.families.map(\.tier), ["basic", "pro"])
        XCTAssertEqual(summary.families.last?.plans.map(\.months), [1, 3, 6, 12])
        XCTAssertEqual(summary.families.last?.plans.map(\.amountCents), [29900, 80730, 152490, 269100])
    }

    func testBillingSummaryLabelsLongTermPlansAndKeepsThemInUsefulOrder() {
        let plans = [
            BillingPlan(id: "basic_annual", name: "Базовый", provider: "platega", amountCents: 179100, currency: "RUB", interval: "annual", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "family_monthly", name: "Team", provider: "platega", amountCents: 149900, currency: "RUB", interval: "monthly", deviceLimit: 10, tier: "team", status: "active"),
            BillingPlan(id: "basic_quarterly", name: "Базовый", provider: "platega", amountCents: 53730, currency: "RUB", interval: "quarterly", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "pro_monthly", name: "Pro", provider: "platega", amountCents: 49900, currency: "RUB", interval: "monthly", deviceLimit: 3, tier: "pro", status: "active"),
            BillingPlan(id: "basic_monthly", name: "Базовый", provider: "platega", amountCents: 19900, currency: "RUB", interval: "monthly", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "basic_semiannual", name: "Базовый", provider: "platega", amountCents: 101490, currency: "RUB", interval: "semiannual", deviceLimit: 1, tier: "basic", status: "active"),
        ]

        let summary = BillingService().buildSummary(plans: plans, entitlement: Entitlement(active: false, vpnAccess: false))

        XCTAssertEqual(summary.plans.map(\.id), [
            "basic_monthly",
            "basic_quarterly",
            "basic_semiannual",
            "basic_annual",
            "pro_monthly",
        ])
        XCTAssertEqual(summary.families.map(\.tier), ["basic", "pro"])
        XCTAssertEqual(summary.families.first?.plans.map(\.months), [1, 3, 6, 12])
        XCTAssertEqual(summary.families.last?.plans.map(\.months), [1])
        XCTAssertTrue(summary.plans.first(where: { $0.id == "basic_quarterly" })?.meta.contains("/3 мес.") == true)
        XCTAssertTrue(summary.plans.first(where: { $0.id == "basic_semiannual" })?.meta.contains("/6 мес.") == true)
        XCTAssertTrue(summary.plans.first(where: { $0.id == "basic_annual" })?.meta.contains("/год") == true)
    }

    func testBillingSummaryDoesNotGuessCurrentDurationFromTierOnlyEntitlement() {
        let plans = [
            BillingPlan(id: "basic_monthly", name: "Базовый", provider: "platega", amountCents: 19900, currency: "RUB", interval: "monthly", deviceLimit: 1, tier: "basic", status: "active"),
            BillingPlan(id: "basic_annual", name: "Базовый", provider: "platega", amountCents: 179100, currency: "RUB", interval: "annual", deviceLimit: 1, tier: "basic", status: "active"),
        ]
        let entitlement = Entitlement(active: true, planId: nil, tier: "basic", vpnAccess: true)

        let summary = BillingService().buildSummary(plans: plans, entitlement: entitlement)

        XCTAssertNil(summary.currentPlan)
        XCTAssertFalse(summary.plans.contains(where: \.current))
        XCTAssertEqual(Set(summary.plans.map(\.action)), ["Сменить"])
    }

    func testBillingIsExternalOnlyWithDashboardFallback() {
        // Payment is external-only now: the app opens the billing dashboard
        // in the browser instead of hosting the plan picker in-app.
        XCTAssertTrue(BillingPresentation.billingDashboardURL.absoluteString.hasPrefix("https://vexguard.app"))
        XCTAssertEqual(BillingPresentation.planName(for: "basic_monthly"), "Базовый · месяц")
    }

    func testPaymentHistoryOpensSpecificVEXReceiptInsteadOfProviderReceipt() {
        let payment = BillingPayment(
            id: "pay_1",
            subscriptionId: nil,
            checkoutSessionId: nil,
            planId: "basic_annual",
            provider: "platega",
            amountMinor: 179100,
            currency: "RUB",
            method: "card",
            status: "paid",
            receiptUrl: "https://pay.platega.io/payment/success?id=provider-secret",
            failureReason: nil,
            refundedAmountMinor: nil,
            refundedAt: nil,
            paidAt: "2026-08-01T12:00:00Z",
            createdAt: "2026-08-01T11:59:00Z"
        )

        XCTAssertEqual(BillingPresentation.customerPaymentURL(for: payment).host, "vexguard.app")
        XCTAssertEqual(
            BillingPresentation.customerPaymentURL(for: payment).path,
            "/dashboard/payments/pay_1/receipt"
        )
        XCTAssertNil(BillingPresentation.customerPaymentURL(for: payment).query)
        XCTAssertEqual(BillingPresentation.planName(for: payment.planId), "Базовый · год")
        XCTAssertEqual(BillingPresentation.planName(for: "business_monthly"), "Бизнес · месяц")
    }

    func testPaymentHistoryUsesClickableRowsWithoutSeparateWebsiteButtons() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let accountPanel = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/AccountPanel.swift"
            ),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(accountPanel.range(of: "private struct PaymentHistoryRow"))
        let rowEnd = try XCTUnwrap(accountPanel.range(of: "private struct EmptyPaymentHistory"))
        let rowSource = accountPanel[rowStart.lowerBound..<rowEnd.lowerBound]
        let historyStart = try XCTUnwrap(accountPanel.range(of: "private var paymentHistory"))
        let historyEnd = try XCTUnwrap(accountPanel.range(of: "private var accessTitle"))
        let historySource = accountPanel[historyStart.lowerBound..<historyEnd.lowerBound]

        XCTAssertFalse(historySource.contains("BillingPresentation.billingDashboardURL"))
        XCTAssertFalse(historySource.contains("Label(\"Кабинет\""))
        XCTAssertTrue(rowSource.contains("Button {"))
        XCTAssertTrue(rowSource.contains("BillingPresentation.customerPaymentURL(for: payment)"))
        XCTAssertTrue(rowSource.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(rowSource.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(rowSource.contains("Label(\"На сайте\""))
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

    func testAutopilotBuildsAWG3EndpointFallbackAttempts() throws {
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
        ])
        XCTAssertTrue(attempts[1].config.contains("Endpoint = de1.vexguard.app:443"))
    }

    func testAutopilotFormatsIPv6FallbackEndpoint() throws {
        let device = try JSONDecoder().decode(VpnDevice.self, from: """
        {"id":"dev_1","name":"Mac","status":"active","protocol":"amneziawg","external_device_id":"macos-test","endpoint":"[2001:db8::1]:8443"}
        """.data(using: .utf8)!)
        let tunnel = PreparedTunnel(
            device: device,
            config: """
            [Interface]
            PrivateKey = x
            [Peer]
            PublicKey = y
            Endpoint = [2001:db8::1]:8443

            """,
            locationId: "ipv6-fallback-test",
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
            "[2001:db8::1]:8443",
            "[2001:db8::1]:443",
        ])
        XCTAssertTrue(attempts[1].config.contains("Endpoint = [2001:db8::1]:443"))
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
        XCTAssertTrue(helperInstaller.contains("PropertyListSerialization.propertyList("))
        XCTAssertTrue(helperInstaller.contains("dictionary[\"RunAtLoad\"] as? Bool == true"))
        XCTAssertTrue(helperInstaller.contains("helperPlistKeepsServiceAvailable(dictionary)"))
        XCTAssertTrue(helperInstaller.contains("SHA256.hash"))
        XCTAssertFalse(helperInstaller.contains("if socketIsConnectable {\n            return\n        }"))
    }

    func testNativeHelperVersionUsesBundledResourceAcrossInstallPaths() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperVersionURL = packageRoot.appendingPathComponent("HelperResources/helper-version")
        let installerURL = packageRoot.appendingPathComponent("HelperResources/install-vex-vpn-helper.sh")
        let nativeInstallerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let buildScriptURL = packageRoot.appendingPathComponent("../scripts/build_native_macos_app.sh").standardizedFileURL
        let helperBuildScriptURL = packageRoot.appendingPathComponent("../scripts/build_swift_macos_helper.sh").standardizedFileURL
        let verifyScriptURL = packageRoot.appendingPathComponent("../scripts/verify_native_macos_runtime.sh").standardizedFileURL

        let helperVersion = try String(contentsOf: helperVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installer = try String(contentsOf: installerURL, encoding: .utf8)
        let nativeInstaller = try String(contentsOf: nativeInstallerURL, encoding: .utf8)
        let buildScript = try String(contentsOf: buildScriptURL, encoding: .utf8)
        let helperBuildScript = try String(contentsOf: helperBuildScriptURL, encoding: .utf8)
        let verifyScript = try String(contentsOf: verifyScriptURL, encoding: .utf8)

        XCTAssertEqual(helperVersion, "36")
        XCTAssertTrue(installer.contains("helper_version_file=\"$src_dir/helper-version\""))
        XCTAssertTrue(nativeInstaller.contains("resourceFile(\"helper-version\")"))
        XCTAssertTrue(buildScript.contains("helper-version"))
        XCTAssertTrue(buildScript.contains("build_swift_macos_helper.sh"))
        XCTAssertTrue(helperBuildScript.contains("VEXPrivilegedHelper"))
        XCTAssertTrue(verifyScript.contains("helper_version_from_bundle"))
        XCTAssertTrue(verifyScript.contains("macos-native/HelperResources/vex-helper"))
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
        let presentationURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Models/FocusPulsePresentation.swift")
        let sidebarURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSidebar.swift")
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        let presentation = try String(contentsOf: presentationURL, encoding: .utf8)
        let sidebar = try String(contentsOf: sidebarURL, encoding: .utf8)

        XCTAssertTrue(home.contains("requiresHelperInstall: helper.installRequiredMessage != nil"))
        XCTAssertTrue(home.contains("await helper.repairHelper()"))
        XCTAssertTrue(presentation.contains("return \"Требуется helper\""))
        XCTAssertTrue(presentation.contains("return \"Установите системный компонент VEX\""))
        XCTAssertTrue(sidebar.contains("return \"Установить helper\""))
        XCTAssertTrue(sidebar.contains("await helper.repairHelper()"))
    }

    func testVpnHeroUsesInstantStateFeedbackWithoutBusyOrbit() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let heroURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseHero.swift")
        let hero = try String(contentsOf: heroURL, encoding: .utf8)

        XCTAssertTrue(hero.contains(".animation(.snappy(duration: 0.16)"))
        XCTAssertTrue(hero.contains("value: status.state"))
        XCTAssertTrue(hero.contains("Image(systemName: \"power\")"))
        XCTAssertFalse(hero.contains("FocusPulseConnectingOrbit"))
        XCTAssertFalse(hero.contains("VEXMiniSpinner"))
        XCTAssertFalse(hero.contains("repeatForever"))
    }

    func testAppLaunchUsesBrandedAnimatedGateWithReducedMotionFallback() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let launchURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXLaunchView.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let launch = try String(contentsOf: launchURL, encoding: .utf8)

        XCTAssertTrue(app.contains("VEXLaunchContainer"))
        XCTAssertTrue(launch.contains("TimelineView(.animation"))
        XCTAssertTrue(launch.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(launch.contains("VEXLaunchTiming.minimumDisplayNanoseconds"))
        XCTAssertTrue(launch.contains("let startupTask = Task"))
        XCTAssertTrue(launch.contains("Защищаем соединение"))
    }

    func testFocusPulseUsesReferenceWindowProportionsAndTransitionEdgeGlow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let glowURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/WindowIntelligenceGlow.swift")
        let dragSurfaceURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/WindowDragSurface.swift")
        let previewModeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Support/VEXPreviewMode.swift")
        let headerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseWindowHeader.swift")
        let heroURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseHero.swift")
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let glow = try String(contentsOf: glowURL, encoding: .utf8)
        let dragSurface = try String(contentsOf: dragSurfaceURL, encoding: .utf8)
        let previewMode = try String(contentsOf: previewModeURL, encoding: .utf8)
        let header = try String(contentsOf: headerURL, encoding: .utf8)
        let hero = try String(contentsOf: heroURL, encoding: .utf8)
        let home = try String(contentsOf: homeURL, encoding: .utf8)

        XCTAssertTrue(app.contains(".defaultSize(width: 920, height: 580)"))
        XCTAssertTrue(app.contains(".windowStyle(.plain)"))
        XCTAssertFalse(app.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertTrue(app.contains(".windowResizability(.contentMinSize)"))
        XCTAssertTrue(app.contains("window.styleMask = [.borderless, .resizable, .miniaturizable]"))
        XCTAssertTrue(app.contains("window.ignoresMouseEvents = false"))
        XCTAssertFalse(app.contains("NSWindow.didResignKeyNotification"))
        XCTAssertTrue(app.contains("red: 0.008"))
        XCTAssertTrue(app.contains("green: 0.039"))
        XCTAssertTrue(app.contains("blue: 0.043"))
        XCTAssertTrue(app.contains("alpha: 1"))
        XCTAssertTrue(app.contains("window.frame.width >= 800"))
        XCTAssertTrue(app.contains("window.contentView?.superview?.layer?.cornerRadius = 16"))
        XCTAssertTrue(app.contains("window.contentView?.superview?.layer?.masksToBounds = true"))
        XCTAssertTrue(app.contains("window.level = .normal"))
        XCTAssertFalse(app.contains("window.level = .floating"))
        XCTAssertTrue(app.contains("window.hidesOnDeactivate = false"))
        XCTAssertTrue(content.contains("WindowIntelligenceGlow("))
        XCTAssertTrue(content.contains("FocusPulseWindowHeader("))
        XCTAssertGreaterThanOrEqual(
            content.components(separatedBy: "FocusPulseWindowHeader(").count - 1,
            3
        )
        XCTAssertEqual(
            content.components(separatedBy: "VEXScrollEdgeBlur(").count - 1,
            2
        )
        XCTAssertTrue(content.contains("edge: .top"))
        XCTAssertTrue(content.contains("edge: .bottom"))
        XCTAssertTrue(content.contains(".padding(.bottom, 110)"))
        XCTAssertFalse(content.contains(".padding(.bottom, 64)"))
        XCTAssertFalse(content.contains(".toolbar {"))
        XCTAssertTrue(content.contains("WindowDragSurface()"))
        XCTAssertFalse(content.contains("WindowDragGesture()"))
        XCTAssertFalse(content.contains(".simultaneousGesture(WindowDragGesture())"))
        XCTAssertFalse(content.contains(".ignoresSafeArea(.container, edges: .top)"))
        XCTAssertTrue(dragSurface.contains("override func acceptsFirstMouse"))
        XCTAssertTrue(dragSurface.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertTrue(dragSurface.contains("window.performDrag(with: event)"))
        XCTAssertTrue(previewMode.contains("static var suppressesRuntime"))
        XCTAssertTrue(previewMode.contains("--signed-out-ui-preview"))
        XCTAssertTrue(glow.contains("TimelineView("))
        XCTAssertTrue(glow.contains(".animation("))
        XCTAssertTrue(glow.contains("accessibilityReduceMotion"))
        XCTAssertTrue(glow.contains("Canvas(rendersAsynchronously: true)"))
        XCTAssertTrue(glow.contains("trimmedPath"))
        XCTAssertTrue(glow.contains("length: 0.16"))
        XCTAssertTrue(glow.contains("lineJoin: .round"))
        XCTAssertFalse(glow.contains("for index in palette.indices"))
        XCTAssertFalse(glow.contains("AngularGradient"))
        XCTAssertTrue(glow.contains("addChildWindow"))
        XCTAssertTrue(glow.contains("addChildWindow(overlay, ordered: .below)"))
        XCTAssertFalse(glow.contains("addChildWindow(overlay, ordered: .above)"))
        XCTAssertTrue(glow.contains("styleMask: .borderless"))
        XCTAssertTrue(glow.contains("ignoresMouseEvents = true"))
        XCTAssertTrue(glow.contains("scheduleGlowFrameSync()"))
        XCTAssertTrue(glow.contains("pendingFrameSync?.cancel()"))
        XCTAssertTrue(glow.contains("display: false"))
        XCTAssertFalse(glow.contains("MainActor.assumeIsolated"))
        XCTAssertFalse(glow.contains("connectedOpacity"))
        XCTAssertTrue(header.contains("focusPulseWindow?.orderOut(nil)"))
        XCTAssertTrue(header.contains("WindowChromeActions.miniaturize()"))
        XCTAssertTrue(header.contains("WindowDragSurface()"))
        XCTAssertTrue(header.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(header.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(header.contains("window.styleMask.insert([.titled"))
        XCTAssertTrue(header.contains("window.miniaturize(nil)"))
        XCTAssertTrue(header.contains("restoreFrames"))
        XCTAssertTrue(header.contains("window.setFrame(visibleFrame"))
        XCTAssertFalse(header.contains("Обновить статус"))
        XCTAssertFalse(header.contains("arrow.clockwise"))
        XCTAssertFalse(header.contains("systemName: \"gearshape\""))
        XCTAssertTrue(hero.contains(".onChange(of: bytes"))
        XCTAssertTrue(hero.contains(".onHover"))
        XCTAssertTrue(hero.contains("isPowerHovered"))
        XCTAssertTrue(hero.contains(".background(alignment: .center)"))
        XCTAssertEqual(
            hero.components(separatedBy: "FocusPulseWaves(").count - 1,
            1
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(hero.range(of: "FocusPulseWaves(")).lowerBound,
            try XCTUnwrap(hero.range(of: "private struct FocusPulsePowerControl")).lowerBound
        )
        XCTAssertTrue(home.contains("ScrollView(.horizontal"))
        XCTAssertTrue(home.contains(".scrollTargetBehavior(.viewAligned)"))
        XCTAssertTrue(home.contains(".containerRelativeFrame("))
        XCTAssertTrue(home.contains(".onHover"))
    }

    func testFocusPulseUsesLivingBackgroundAndAnimatedNavigationStates() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let backgroundURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/BackgroundViews.swift")
        let dockURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseNavigationDock.swift")
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let serverWindowURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Support/VEXServerSidebarWindow.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let background = try String(contentsOf: backgroundURL, encoding: .utf8)
        let dock = try String(contentsOf: dockURL, encoding: .utf8)
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        let serverWindow = try String(contentsOf: serverWindowURL, encoding: .utf8)

        XCTAssertTrue(content.contains("VEXBackground(selection: selection)"))
        XCTAssertTrue(content.contains(".contentTransition(.opacity)"))
        XCTAssertTrue(content.contains(".asymmetric("))
        XCTAssertFalse(background.contains("TimelineView("))
        XCTAssertFalse(background.contains("scenePhase"))
        XCTAssertTrue(background.contains(".easeInOut(duration: 0.35)"))
        XCTAssertTrue(background.contains("AngularGradient("))
        XCTAssertTrue(background.contains("selection.accentColor"))
        XCTAssertFalse(background.contains("repeatForever"))
        XCTAssertTrue(dock.contains("@State private var hoveredSection"))
        XCTAssertTrue(dock.contains("accessibilityReduceMotion"))
        XCTAssertTrue(dock.contains(".snappy(duration: 0.32"))
        XCTAssertTrue(dock.contains(".onHover"))
        XCTAssertTrue(dock.contains("hoveredSection =="))
        XCTAssertTrue(dock.contains("section: .settings"))
        XCTAssertTrue(dock.contains("systemName: \"gearshape\""))
        XCTAssertFalse(dock.contains("onShowServers"))
        XCTAssertFalse(dock.contains("globe.europe.africa.fill"))
        XCTAssertFalse(content.contains("presentedSheet"))
        XCTAssertTrue(home.contains("FocusPulseLocations("))
        XCTAssertTrue(content.contains("HomePanel(onShowServers: VEXServerSidebarWindow.toggle)"))
        XCTAssertFalse(content.contains("isServerDrawerPresented"))
        XCTAssertTrue(serverWindow.contains("mainWindow.addChildWindow(panel, ordered: .above)"))
        XCTAssertTrue(serverWindow.contains("ServerSidebarPlacement.frame("))
    }

    func testHomeKeepsProtectionControlsInSettingsAndWebsiteInBottomCorner() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let dockURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseNavigationDock.swift")
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let settingsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSettingsView.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let dock = try String(contentsOf: dockURL, encoding: .utf8)
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(content.contains("FocusPulseNavigationDock("))
        XCTAssertTrue(content.contains("selection: $selection"))
        XCTAssertTrue(content.contains("availableUpdateVersion: appState.availableNativeUpdateVersion"))
        XCTAssertTrue(content.contains(".zIndex(10)"))
        XCTAssertTrue(dock.contains("VEXPreviewMode.isEnabled"))
        XCTAssertTrue(dock.contains("legacyDock"))
        XCTAssertTrue(dock.contains(".fill(.ultraThinMaterial)"))
        XCTAssertFalse(dock.contains(".background(.ultraThinMaterial, in: Capsule())"))
        XCTAssertFalse(dock.contains("Color.white.opacity(0.10)"))
        XCTAssertFalse(home.contains("FocusPulseQuickControls"))
        XCTAssertFalse(home.contains("Умный режим"))
        XCTAssertFalse(home.contains("Kill Switch"))
        XCTAssertTrue(settings.contains("title: \"Умный режим\""))
        XCTAssertTrue(settings.contains("title: \"Kill Switch\""))
        XCTAssertTrue(settings.contains("isOn: $appState.antiLeakEnabled"))
        XCTAssertFalse(home.contains("Link(destination: Self.websiteURL)"))
        XCTAssertTrue(content.contains("VEXWebsiteLink()"))
        XCTAssertTrue(content.contains(".padding(.trailing, 20)"))
        XCTAssertTrue(content.contains(".padding(.bottom, 20)"))
        XCTAssertTrue(content.contains("https://vexguard.app"))
        XCTAssertTrue(content.contains("accessibilityLabel(\"Открыть сайт VEX\")"))
        XCTAssertTrue(content.contains("Color.vexCyanLight.opacity(0.82)"))
        XCTAssertTrue(content.contains(".padding(.top, 82)"))
        XCTAssertTrue(settings.contains(".toggleStyle(VEXSwitchToggleStyle())"))
    }

    func testSettingsAndAccountKeepBrandedHierarchyWithoutDecorativeOuterSurfaces() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settingsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSettingsView.swift")
        let accountURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/AccountPanel.swift")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        let account = try String(contentsOf: accountURL, encoding: .utf8)

        XCTAssertTrue(settings.contains("SettingsHero("))
        XCTAssertTrue(settings.contains("SettingsFeatureCard("))
        XCTAssertFalse(settings.contains("LinearGradient("))
        XCTAssertTrue(account.contains("AccountHero("))
        XCTAssertTrue(account.contains("VEXFeatureSurface("))
        XCTAssertFalse(account.contains("VEXFeatureSurface(accent: .vexCyan"))
        XCTAssertFalse(account.contains(".blur(radius: 38)"))
        XCTAssertFalse(account.contains("AccountMetric("))
        XCTAssertFalse(account.contains("receiptUrl"))
        XCTAssertTrue(account.contains("Оплатить на сайте"))
        XCTAssertFalse(settings.contains("title: \"VPN\""))
        XCTAssertFalse(settings.contains("VEXAppInfo.coreVersion"))
        XCTAssertFalse(settings.contains("VEXAppInfo.apiClientVersion"))
    }

    func testEnabledSettingsSwitchesUseVisibleVEXAccentTrack() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settingsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSettingsView.swift")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(settings.contains(".toggleStyle(VEXSwitchToggleStyle())"))
        XCTAssertTrue(settings.contains("configuration.isOn ? Color.vexCyan"))
        XCTAssertTrue(settings.contains("configuration.isOn ? 8 : -8"))
        XCTAssertTrue(settings.contains("configuration.isOn ? \"Включено\" : \"Выключено\""))
        XCTAssertFalse(settings.contains(".toggleStyle(.switch)"))
        XCTAssertFalse(settings.contains(".tint(Color.vexCyan)"))
    }

    func testStatusItemOpensAnimatedVEXTrayPanelInsteadOfLegacyMenu() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/StatusBar/VEXStatusItemController.swift")
        let trayURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXTrayPanelView.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let tray = try String(contentsOf: trayURL, encoding: .utf8)

        XCTAssertTrue(app.contains("button.action = #selector(togglePanel)"))
        XCTAssertTrue(app.contains("button.sendAction(on: [.leftMouseDown, .rightMouseDown])"))
        XCTAssertFalse(app.contains("button.sendAction(on: [.leftMouseUp, .rightMouseUp])"))
        XCTAssertTrue(app.contains("item.menu = nil"))
        XCTAssertTrue(app.contains("VEXTrayPanel("))
        XCTAssertTrue(app.contains("NSAnimationContext.runAnimationGroup"))
        XCTAssertTrue(app.contains("addGlobalMonitorForEvents"))
        XCTAssertTrue(app.contains("NSWindow.Level.popUpMenu.rawValue + 1"))
        XCTAssertTrue(app.contains("window.backgroundColor = .clear"))
        XCTAssertTrue(tray.contains("struct VEXTrayPanelView: View"))
        XCTAssertTrue(tray.contains("appState.toggleVPNPower(using: helper)"))
        XCTAssertTrue(tray.contains(".onHover"))
        XCTAssertTrue(tray.contains("accessibilityReduceMotion"))
        XCTAssertTrue(tray.contains("Открыть VEX"))
        XCTAssertTrue(tray.contains("https://vexguard.app"))
        XCTAssertTrue(tray.contains("Открыть сайт VEX"))
    }

    func testTrayPanelSharesTheMainClientVisualLanguage() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let trayURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXTrayPanelView.swift")
        let tray = try String(contentsOf: trayURL, encoding: .utf8)

        XCTAssertTrue(tray.contains("VEXBackground(selection: .home)"))
        XCTAssertTrue(tray.contains("CircuitBackdrop()"))
        XCTAssertTrue(tray.contains("connectionPulse"))
        XCTAssertTrue(tray.contains("trafficStrip"))
        XCTAssertTrue(tray.contains("routeCard"))
        XCTAssertTrue(tray.contains("Color.vexPanelStrong.opacity"))
        XCTAssertTrue(tray.contains("Color.white.opacity(hoveredAction == .openApp"))
        XCTAssertFalse(tray.contains("Color.vexCyan.opacity(hoveredAction == .openApp ? 0.98 : 0.86)"))
        XCTAssertTrue(tray.contains("VEXTrayLayout.size.width"))
        XCTAssertTrue(tray.contains("VEXTrayLayout.size.height"))
        XCTAssertFalse(tray.contains(".background(.regularMaterial)"))

        let statusURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/StatusBar/VEXStatusItemController.swift")
        let status = try String(contentsOf: statusURL, encoding: .utf8)
        XCTAssertTrue(status.contains("VEXTrayLayout.size"))
        XCTAssertFalse(status.contains("width: 388, height: 472"))
        XCTAssertTrue(status.contains("panel.makeKey()"))
    }

    func testTrayPanelFrameStaysInsideAvailableScreen() {
        let screen = CGRect(x: -400, y: 0, width: 380, height: 480)
        let statusItem = CGRect(x: -60, y: 452, width: 24, height: 20)

        let frame = VEXTrayLayout.panelFrame(below: statusItem, inside: screen)

        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + VEXTrayLayout.screenMargin)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - VEXTrayLayout.screenMargin)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + VEXTrayLayout.screenMargin)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - VEXTrayLayout.screenMargin)
    }

    func testTrayPanelStaysAboveOtherAppsWithoutOpeningMainWindow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let statusURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/StatusBar/VEXStatusItemController.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let status = try String(contentsOf: statusURL, encoding: .utf8)

        XCTAssertTrue(status.contains("NSApp.preventWindowOrdering()"))
        XCTAssertTrue(status.contains("panel.orderFrontRegardless()"))
        XCTAssertTrue(status.contains("NSWindow.Level.popUpMenu.rawValue + 1"))
        XCTAssertTrue(status.contains(".canJoinAllSpaces"))
        XCTAssertTrue(status.contains("NSRunningApplication.current.activate("))
        XCTAssertTrue(status.contains(".activateAllWindows"))
        XCTAssertTrue(status.contains("mainWindow?.orderFrontRegardless()"))
        XCTAssertFalse(status.contains("--tray-panel-preview"))
        XCTAssertTrue(status.contains("button.image = Self.statusItemImage()"))
        XCTAssertTrue(status.contains("image.isTemplate = false"))
        XCTAssertTrue(status.contains(".foregroundColor: NSColor.white"))
        XCTAssertTrue(status.contains("button.contentTintColor = .white"))
        XCTAssertTrue(app.contains("NSRunningApplication.current.activate("))
        XCTAssertTrue(app.contains("window.orderFrontRegardless()"))
        XCTAssertTrue(status.contains("event.windowNumber == panel.windowNumber"))
        XCTAssertTrue(status.contains("panel.frame.insetBy(dx: -8, dy: -8).contains(pointer)"))
    }

    @MainActor
    func testFocusPulseMainWindowKeepsNativeActivationWhileChromeIsHidden() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        FocusPulseMainWindowConfiguration.apply(to: window)
        window.contentViewController = NSViewController()
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)

        WindowChromeActions.miniaturize(window: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(window.isMiniaturized)
        window.deminiaturize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let originalFrame = window.frame
        WindowChromeActions.zoom(window: window)
        XCTAssertNotEqual(window.frame, originalFrame)
        WindowChromeActions.zoom(window: window)
        XCTAssertEqual(window.frame, originalFrame)
    }

    func testMainWindowMouseDownExplicitlyReactivatesPlainSwiftUIWindow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(app.contains("mainWindowActivationMonitor"))
        XCTAssertTrue(app.contains("NSEvent.addLocalMonitorForEvents("))
        XCTAssertTrue(app.contains("matching: [.leftMouseDown, .rightMouseDown]"))
        XCTAssertTrue(app.contains("event.window === window"))
        XCTAssertTrue(app.contains("activateMainWindow(window)"))
        XCTAssertTrue(app.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(app.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertTrue(app.contains("NSEvent.removeMonitor(mainWindowActivationMonitor)"))
    }

    func testHelperPollingDoesNotPublishUnchangedStatus() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let helper = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helper.contains("let nextStatus = VpnStatus(helperResponse: response)"))
        XCTAssertTrue(helper.contains("if status != nextStatus"))
        XCTAssertTrue(helper.contains("status = nextStatus"))
    }

    func testHelperPollingBacksOffOutsideTransitions() {
        let connected = VpnStatus(
            helperResponse: "state=connected route_ok=true socket_exists=true iface=utun9 rx=1 tx=1"
        )

        XCTAssertEqual(VEXHelperModel.pollIntervalNanoseconds(for: connected), 15_000_000_000)
        XCTAssertEqual(VEXHelperModel.pollIntervalNanoseconds(for: .disconnected), 30_000_000_000)
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

    func testPackagedAppResolvesSwiftPMResourcesFromContentsResources() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sharedViewsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/SharedViews.swift")
        let preflightURL = packageRoot.appendingPathComponent("../scripts/native_macos_production_preflight.sh").standardizedFileURL
        let sharedViews = try String(contentsOf: sharedViewsURL, encoding: .utf8)
        let preflight = try String(contentsOf: preflightURL, encoding: .utf8)

        XCTAssertTrue(sharedViews.contains("Contents/Resources"))
        XCTAssertTrue(sharedViews.contains("VEXNativeMac_VEXNativeMac.bundle"))
        XCTAssertFalse(sharedViews.contains("Bundle.module.image"))
        XCTAssertTrue(preflight.contains("Contents/Resources/VEXNativeMac_VEXNativeMac.bundle"))
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

    func testNativeHelperInstallerRecoversNetworkBeforeDiscardingState() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot.appendingPathComponent("HelperResources/install-vex-vpn-helper.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("antileak.state"))
        XCTAssertTrue(script.contains("antileak.active"))
        XCTAssertTrue(script.contains("operation.lock"))
        XCTAssertTrue(script.contains("utun.name"))
        XCTAssertTrue(script.contains("/sbin/pfctl -a \"$antileak_anchor\" -F all"))
        XCTAssertTrue(script.contains("/sbin/pfctl -a \"$antileak_anchor\" -sr 2>/dev/null"))
        XCTAssertFalse(script.contains("/sbin/pfctl -a \"$antileak_anchor\" -sr 2>&1"))
        XCTAssertTrue(script.contains("/usr/bin/printf 'shutdown\\n'"))
        XCTAssertTrue(script.contains("/usr/bin/printf 'down\\n'"))
        XCTAssertTrue(script.contains("Replacement helper did not confirm network recovery"))
        XCTAssertTrue(script.contains("Keep the pre-replacement recovery evidence"))
        XCTAssertFalse(script.contains("shutdown_response\" == \"ok\""))
        XCTAssertFalse(script.contains("/bin/rm -f \"$helper_dir/antileak.state\""))
    }

    func testHelperRepairActionIsSeparateFromVpnConnect() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let helperInstallerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let homeURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/HomePanel.swift")
        let heroURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/FocusPulseHero.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let helperInstaller = try String(contentsOf: helperInstallerURL, encoding: .utf8)
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        let hero = try String(contentsOf: heroURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("func repairHelper() async"))
        XCTAssertTrue(helperModel.contains("@Published private(set) var installationPhase"))
        XCTAssertTrue(helperModel.contains("installer.repairWithAdminPrivileges"))
        XCTAssertTrue(helperModel.contains("installationPhase = .failed"))
        XCTAssertTrue(helperModel.contains("Helper установлен."))
        XCTAssertTrue(helperModel.contains("var installRequiredMessage: String?"))
        XCTAssertTrue(helperInstaller.contains("private func installWithAdminPrivileges("))
        XCTAssertTrue(helperInstaller.contains("async throws"))
        XCTAssertTrue(helperInstaller.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(helperInstaller.contains("VEX Inc. устанавливает системный компонент VEX"))
        XCTAssertTrue(helperInstaller.contains("waitForSocket(timeout: 8.0)"))
        XCTAssertTrue(helperInstaller.contains("Date().addingTimeInterval(0.5)"))
        XCTAssertTrue(helperModel.contains("Task.sleep(for: .milliseconds(500))"))
        XCTAssertTrue(home.contains("installationPhase: helper.installationPhase"))
        XCTAssertTrue(hero.contains("return installationPhase.detail"))
        XCTAssertTrue(hero.contains("TimelineView(.animation"))
        XCTAssertTrue(hero.contains("HelperInstallProgressRing"))
    }

    func testDesktopShowsInstalledVersionInLowerLeftCorner() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)

        XCTAssertTrue(content.contains("VEXVersionLabel()"))
        XCTAssertTrue(content.contains("alignment: .bottomLeading"))
        XCTAssertTrue(content.contains("VEX \\(VEXAppInfo.version) · build \\(VEXAppInfo.buildNumber)"))
    }

    func testNativeConnectUsesOneAtomicHelperUpAndWaitsForUsableStatus() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let helperRuntimeURL = packageRoot
            .appendingPathComponent("Sources/VEXHelperCore/Runtime.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let helperRuntime = try String(contentsOf: helperRuntimeURL, encoding: .utf8)

        XCTAssertFalse(helperModel.contains("shouldDisconnectBeforeConnect"))
        XCTAssertFalse(helperModel.contains("silentDisconnect(releaseAntiLeak: false)"))
        XCTAssertTrue(helperRuntime.contains("tunnelController.bringUp("))
        XCTAssertTrue(helperRuntime.contains("store.withOperationLock"))
        XCTAssertTrue(helperModel.contains("refreshConnectedStatusUntilStable"))
        XCTAssertTrue(helperModel.contains("status.isUsableConnectedStatus"))
        XCTAssertTrue(helperModel.contains("private let handshakePatienceDeadline: Duration = .seconds(8)"), "Slow first handshakes must not trigger tunnel teardown")
        XCTAssertTrue(helperModel.contains("let structurallyUp = status.socketExists"))
        XCTAssertTrue(helperModel.contains("structurallyUp ? patientDeadline : quickDeadline"))
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

    func testNativeAppQuitFailsOpenAndKeepsCrashWatchdogArmed() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXNativeMacApp.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let app = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("func shutdownForAppTermination() async"))
        XCTAssertTrue(helperModel.contains("pollTask?.cancel()"))
        XCTAssertTrue(helperModel.contains("try await client.sendExpectingOK(\"shutdown\", timeoutSeconds: 2)"))
        XCTAssertTrue(helperModel.contains("attach-owner owner_pid="))
        XCTAssertFalse(helperModel.contains("await detachOwnerWatchdog(quiet: true)\n                    message = successMessage"))
        XCTAssertFalse(helperModel.contains("await detachOwnerWatchdog(quiet: true)\n        } catch"))
        XCTAssertTrue(app.contains("await helper.shutdownForAppTermination()"))
        XCTAssertTrue(app.contains("sender.reply(toApplicationShouldTerminate: true)"))
        XCTAssertTrue(app.contains("return .terminateLater"))
    }

    func testHelperDaemonRestartsAfterCleanAppQuitSoNextLaunchNeedsNoPassword() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let installURL = packageRoot.appendingPathComponent("HelperResources/install-vex-vpn-helper.sh")
        let installerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let install = try String(contentsOf: installURL, encoding: .utf8)
        let installer = try String(contentsOf: installerURL, encoding: .utf8)

        XCTAssertTrue(install.contains("<key>KeepAlive</key>\n  <true/>"))
        XCTAssertFalse(install.contains("<key>SuccessfulExit</key>"))
        XCTAssertTrue(installer.contains("helperPlistKeepsServiceAvailable"))
    }

    func testNativeHelperPreservesExistingMacOSVpnServicesDuringConnect() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperURL = packageRoot.appendingPathComponent("HelperResources/awg-quick.sh")
        let helper = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helper.contains("collect_gateways"))
        XCTAssertTrue(helper.contains("collect_endpoints"))
        XCTAssertTrue(helper.contains("add_route"))
        XCTAssertTrue(helper.contains("del_routes"))
        XCTAssertFalse(helper.contains("killall"))
    }

    func testNativeHelperSocketRemainsAccessibleToAppUser() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperURL = packageRoot.appendingPathComponent("Sources/VEXHelperCore/Runtime.swift")
        let helper = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helper.contains("\"_windowserver\""))
        XCTAssertTrue(helper.contains("SCDynamicStoreCopyConsoleUser"))
        XCTAssertTrue(helper.contains("chown(socketPath, uid, gid)"))
        XCTAssertTrue(helper.contains("chmod(socketPath, 0o600)"))
        XCTAssertTrue(helper.contains("startSocketOwnershipMonitor"))
        XCTAssertFalse(helper.contains("0o660"))
    }

    func testFailedConnectAlwaysReleasesAntiLeak() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helperModelURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/VEXHelperClient.swift")
        let appStateURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift")
        let firewallURL = packageRoot.appendingPathComponent("Sources/VEXHelperCore/SystemSupport.swift")
        let helperModel = try String(contentsOf: helperModelURL, encoding: .utf8)
        let appState = try String(contentsOf: appStateURL, encoding: .utf8)
        let firewall = try String(contentsOf: firewallURL, encoding: .utf8)

        XCTAssertTrue(helperModel.contains("await client.silentDisconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(appState.contains("await helper.interruptWithDisconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(appState.contains("await helper.disconnect(releaseAntiLeak: true)"))
        XCTAssertTrue(firewall.contains("let rollback = try? runQuick(\"down\", configPath: configPath)"))
        XCTAssertTrue(firewall.contains("try fileSystem.removeItem(at: paths.legacyAntileakStatePath)"))
    }

    func testAntiLeakAllowsProtectedControlPlaneHttps() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let firewallURL = packageRoot.appendingPathComponent("Sources/VEXHelperCore/SystemSupport.swift")
        let firewall = try String(contentsOf: firewallURL, encoding: .utf8)

        XCTAssertTrue(firewall.contains("94.141.160.212"))
        XCTAssertTrue(firewall.contains("31.77.199.171"))
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

    func testCustomWindowAndSettingsExposeAccessibleInteractionContracts() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let settingsURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/VEXSettingsView.swift")
        let sharedURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/SharedViews.swift")
        let backgroundURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/BackgroundViews.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        let shared = try String(contentsOf: sharedURL, encoding: .utf8)
        let background = try String(contentsOf: backgroundURL, encoding: .utf8)

        XCTAssertTrue(content.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(content.contains("accessibilityReduceMotion"))
        XCTAssertTrue(settings.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(settings.contains(".accessibilityHint(subtitle)"))
        XCTAssertTrue(settings.contains(".accessibilityLabel(\"Язык интерфейса\")"))
        XCTAssertTrue(shared.contains("accessibilityReduceMotion"))
        XCTAssertTrue(background.contains("accessibilityReduceMotion"))
    }

    func testProfileAndHomeShareOneVisualSurfaceHierarchy() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift")
        let sharedURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/SharedViews.swift")
        let accountURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/AccountPanel.swift")
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let shared = try String(contentsOf: sharedURL, encoding: .utf8)
        let account = try String(contentsOf: accountURL, encoding: .utf8)

        XCTAssertTrue(content.contains(".padding(.top, 82)"))
        XCTAssertTrue(content.contains(".padding(.top, 72)"))
        XCTAssertTrue(content.contains(".zIndex(30)"))
        XCTAssertTrue(shared.contains("struct VEXFeatureSurface"))
        XCTAssertFalse(account.contains("VEXFeatureSurface(accent: .vexCyan"))
        XCTAssertTrue(account.contains("AccountSurfaceCard(accent: .vexMuted)"))
        XCTAssertFalse(account.contains(".blur(radius: 38)"))
        XCTAssertFalse(shared.contains(".overlay(alignment: .top)"))
        XCTAssertFalse(shared.contains(".stroke(accent.opacity(0.16), lineWidth: 1)"))
        XCTAssertFalse(account.contains(".overlay(alignment: .leading)"))
    }

    func testAsyncSleepsAndEmptyResponsesUseCancellationAndCheckedCasts() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let installerURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXHelperInstaller.swift")
        let autopilotURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VpnAutopilotService.swift")
        let apiURL = packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/VEXAPIClient.swift")
        let installer = try String(contentsOf: installerURL, encoding: .utf8)
        let autopilot = try String(contentsOf: autopilotURL, encoding: .utf8)
        let api = try String(contentsOf: apiURL, encoding: .utf8)

        XCTAssertFalse(installer.contains("try? await Task.sleep"))
        XCTAssertFalse(autopilot.contains("try? await Task.sleep"))
        XCTAssertFalse(api.contains("as! T"))
        XCTAssertTrue(api.contains("as? T"))
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

    func testExpectedIPv6RouteConflictStopsUsableStateAndExplainsProtection() {
        let status = VpnStatus(helperResponse: "state=error iface=utun6 route_ok=true route_iface=utun6 ipv6_route_expected=true ipv6_route_ok=false ipv6_route_iface=utun0 socket_exists=true rx=92 tx=11264 latest_handshake=0\n")

        XCTAssertFalse(status.isUsableConnectedStatus)
        XCTAssertTrue(status.hasIPv6RouteConflict)
        XCTAssertEqual(
            status.routeConflictMessage,
            "IPv6 удерживает другой VPN. Подключение VEX остановлено, чтобы исключить утечку трафика."
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
            VEXUserFacingText.status("The data couldn’t be read because it is missing."),
            "Системный компонент VEX запускается..."
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

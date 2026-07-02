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

        XCTAssertTrue(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedRoutingMode: .allExceptRu))
        XCTAssertFalse(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedRoutingMode: .fullTunnel))
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

        XCTAssertFalse(VPNProfileService.cachedProfileNeedsRefresh(cached, requestedRoutingMode: .allExceptRu))
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
        XCTAssertFalse(keyAssessment.canFailover)

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

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VEXNativeMac

@MainActor
final class VPNProfileServiceIdentityTests: XCTestCase {
    func testFreshCacheForAIsNeverReturnedToB() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.cache.save(fixture.record(owner: "account-a"), locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: try fixture.device(owner: "account-b", id: "device-b"), profile: fixture.profile(deviceId: "device-b"))

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "token-b", userId: "account-b",
            locationId: "de", routingMode: .fullTunnel, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(tunnel.device.id, "device-b")
        XCTAssertEqual(network.paths, ["/v1/devices", "/v1/vpn/profile"])
        XCTAssertEqual(network.knownVersions, [nil])
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a")?.device.id, "device-a")
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-b")?.device.id, "device-b")
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testFreshQualifiedCacheWithPaidProofNeedsNoRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: record.device, profile: fixture.profile())

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "rotated-session-token", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(tunnel, record.tunnel)
        XCTAssertTrue(network.paths.isEmpty)
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testCanceledActivationCannotWriteEvenTheIsolatedHelperFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        let service = fixture.service(Network(device: record.device, profile: fixture.profile()))

        do {
            try await service.writeHelperConfig(for: record.tunnel, shouldWrite: { false })
            XCTFail("An invalidated activation must stop before the helper config write")
        } catch is CancellationError { }
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testMissingEntitlementProofCannotBypassUnauthorizedLiveResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: record.device, profile: fixture.profile(), statusCode: 401)

        do {
            _ = try await fixture.service(network).resolveProfile(accessToken: "expired-token", userId: "account-a",
                locationId: "de", routingMode: .fullTunnel, writeHelperConfig: false)
            XCTFail("Unauthorized live response must not fall back to a fresh profile")
        } catch {
            XCTAssertTrue(error.isUnauthorizedAPIError)
        }
        XCTAssertEqual(network.paths, ["/v1/billing/entitlement"])
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), record)
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testUnknownAccountAuthenticatesAndConfirmsDeviceInsteadOfTrustingFreshCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: record.device, profile: fixture.profile(unchanged: true))

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "token-a",
            locationId: "de", routingMode: .fullTunnel, writeHelperConfig: false)

        XCTAssertEqual(tunnel.device.id, "device-a")
        XCTAssertEqual(network.paths, ["/v1/auth/me", "/v1/billing/entitlement", "/v1/devices", "/v1/vpn/profile"])
        XCTAssertEqual(network.knownVersions, [123])
    }

    func testLegacyCacheRemainsAHintUntilUnconditionalLiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = try fixture.record()
        record.accountUserId = nil
        record.localKeyEpoch = nil
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: record.device, profile: fixture.profile())

        _ = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(network.knownVersions, [nil])
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel), record)
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a")?.accountUserId, "account-a")
    }

    func testDeviceReplacementCannotSendOldKnownVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.cache.save(fixture.record(), locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: try fixture.device(id: "replacement"), profile: fixture.profile(deviceId: "replacement"))

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(tunnel.device.id, "replacement")
        XCTAssertEqual(network.knownVersions, [nil])
    }

    func testCompactResponseWithoutIdentityGetsOneUnconditionalFetch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let legacyCompact: [String: Any] = ["unchanged": true, "version": 123]
        let network = Network(device: record.device, profiles: [legacyCompact, fixture.profile()])

        _ = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(network.knownVersions, [123, nil])
    }

    func testConfirmedCompactResponsePreservesRoutingMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let network = Network(device: record.device, profile: fixture.profile(unchanged: true))

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(network.knownVersions, [123])
        XCTAssertEqual(tunnel.bypassRangesCount, record.bypassRangesCount)
        XCTAssertEqual(tunnel.bypassDomainsCount, record.bypassDomainsCount)
        XCTAssertEqual(tunnel.routingPolicyVersion, record.routingPolicyVersion)
    }

    func testWrongLiveProfileKeyCannotOverwriteQualifiedCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        var wrong = fixture.profile()
        wrong["client_public_key"] = "another-client-key"
        let network = Network(device: record.device, profile: wrong)

        do {
            _ = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
                locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)
            XCTFail("Mismatched live profile must be rejected")
        } catch VPNProfileError.profileIdentityMismatch { }
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), record)
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testLocalKeyChangeDuringLiveRequestCannotPersistOldProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        let store = WireGuardKeyStore(fileStore: fixture.fileStore)
        let replacement = WireGuardKeyPair(privateKey: Data(repeating: 21, count: 32).base64EncodedString(),
            publicKey: Data(repeating: 22, count: 32).base64EncodedString(), keyEpoch: 8)
        let network = Network(device: record.device, profile: fixture.profile(), onProfile: { try store.save(replacement) })

        do {
            _ = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
                locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)
            XCTFail("A response for the old local key must be rejected")
        } catch VPNProfileError.profileIdentityMismatch { }
        XCTAssertEqual(try store.getOrCreate(), replacement)
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), record)
        XCTAssertNil(fixture.cache.readHelperConfig())
    }

    func testFullProfileCanConfirmServerEpochAdvanceWithoutReusingOldConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        try fixture.cache.save(record, locationId: "de", routingMode: .fullTunnel)
        var advanced = fixture.profile()
        advanced["client_key_epoch"] = 8
        let network = Network(device: record.device, profile: advanced)

        let tunnel = try await fixture.service(network).resolveProfile(accessToken: "token-a", userId: "account-a",
            locationId: "de", routingMode: .fullTunnel, forceRefresh: true, writeHelperConfig: false, prevalidatedEntitlement: fixture.paid)

        XCTAssertEqual(tunnel.device.keyEpoch, 8)
        XCTAssertEqual(fixture.cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a")?.localKeyEpoch, 7)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VPNProfileServiceIdentityTests-\(UUID().uuidString)")
        let keyPair = WireGuardKeyPair(privateKey: Data(repeating: 11, count: 32).base64EncodedString(),
            publicKey: Data(repeating: 12, count: 32).base64EncodedString(), keyEpoch: 7)
        let paid = Entitlement(active: true, vpnAccess: true)
        var cache: VPNProfileCache { VPNProfileCache(directoryURL: directory, helperConfigURL: directory.appendingPathComponent("helper/vex.conf")) }
        var fileStore: AppSensitiveFileStore { AppSensitiveFileStore(directoryURL: directory.appendingPathComponent("sensitive")) }

        init() throws {
            try WireGuardKeyStore(fileStore: fileStore).save(keyPair)
            try fileStore.setString("vexd_fixture", for: "vex.auth.device_id")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        @MainActor func service(_ network: Network) -> VPNProfileService {
            var api = VEXAPIClient()
            api.baseURL = URL(string: "https://api.example.invalid")!
            api.transport.load = { request in try network.respond(to: request) }
            return VPNProfileService(api: api, identityStore: VEXDeviceIdentityStore(fileStore: fileStore),
                keyStore: WireGuardKeyStore(fileStore: fileStore), cache: cache)
        }

        func device(owner: String = "account-a", id: String = "device-a") throws -> VpnDevice {
            let object: [String: Any] = ["id": id, "user_id": owner, "status": "active", "assigned_ipv4": "192.0.2.2/32",
                "public_key": keyPair.publicKey, "psk_epoch": 7, "protocol": "amneziawg", "provisioning_mode": "managed_native",
                "client_key_ownership": "client", "external_device_id": "vexd_fixture", "platform": "macos", "app_version": VEXAppInfo.version]
            return try JSONDecoder().decode(VpnDevice.self, from: JSONSerialization.data(withJSONObject: object))
        }

        func record(owner: String = "account-a") throws -> PreparedTunnelCacheRecord {
            PreparedTunnelCacheRecord(tunnel: PreparedTunnel(device: try device(owner: owner), config: config,
                locationId: "de", profileVersion: 123, routingMode: .fullTunnel, bypassRegion: nil,
                bypassRangesCount: 9, bypassDomainsCount: 4, routingPolicyVersion: "fixture-policy", rotationRequired: false),
                accountUserId: owner, localKeyEpoch: keyPair.keyEpoch)
        }

        var config: String {
            "[Interface]\nPrivateKey = \(keyPair.privateKey)\nAddress = 192.0.2.2/32\n[Peer]\nPublicKey = \(Data(repeating: 13, count: 32).base64EncodedString())\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n"
        }

        func profile(deviceId: String = "device-a", unchanged: Bool = false) -> [String: Any] {
            var object: [String: Any] = ["unchanged": unchanged, "version": 123, "device_id": deviceId,
                "client_public_key": keyPair.publicKey, "client_key_epoch": 7, "revoked": false, "rotation_required": false]
            if !unchanged { object["config"] = config; object["assigned_ipv4"] = "192.0.2.2/32" }
            return object
        }
    }

    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private let device: VpnDevice
        private var profiles: [[String: Any]]
        private var requests: [URLRequest] = []
        private let statusCode: Int
        private let onProfile: (@Sendable () throws -> Void)?

        init(device: VpnDevice, profile: [String: Any], statusCode: Int = 200, onProfile: (@Sendable () throws -> Void)? = nil) {
            self.device = device; profiles = [profile]; self.statusCode = statusCode; self.onProfile = onProfile
        }
        init(device: VpnDevice, profiles: [[String: Any]]) {
            self.device = device; self.profiles = profiles; statusCode = 200; onProfile = nil
        }

        var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0.url?.path } }
        var knownVersions: [Int?] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.url?.path == "/v1/vpn/profile" }.map {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "known_version" }?.value.flatMap(Int.init)
            }
        }

        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let data: Data
            switch request.url?.path {
            case "/v1/auth/me": data = try JSONEncoder().encode(VEXUser(id: device.userId ?? "account-a", email: "fixture@example.invalid", status: "active"))
            case "/v1/billing/entitlement": data = try JSONEncoder().encode(Entitlement(active: true, vpnAccess: true))
            case "/v1/devices": data = try JSONEncoder().encode([device])
            case "/v1/vpn/profile":
                try onProfile?()
                guard !profiles.isEmpty else { throw VEXAPIError.invalidResponse }
                data = try JSONSerialization.data(withJSONObject: profiles.removeFirst())
            default: throw VEXAPIError.invalidResponse
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
        }
    }
}

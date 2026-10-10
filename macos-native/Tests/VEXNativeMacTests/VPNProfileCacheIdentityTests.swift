import Foundation
import XCTest
@testable import VEXNativeMac

final class VPNProfileCacheIdentityTests: XCTestCase {
    func testMatchingAccountDeviceKeysAndProfileCanBeReused() throws {
        let cached = try fixture()
        XCTAssertTrue(canReuse(cached))
        XCTAssertTrue(canReuse(cached, currentDevice: cached.device))

        var legacyInstallation = cached
        legacyInstallation.device.externalDeviceId = "installation-a:de"
        var currentDevice = legacyInstallation.device
        currentDevice.externalDeviceId = "installation-a:nl"
        currentDevice.assignedIpv4 = "10.8.0.2/32"
        XCTAssertTrue(canReuse(legacyInstallation, currentDevice: currentDevice))
    }

    func testCacheCannotCrossAccountDeviceKeyOrRouteBoundaries() throws {
        let original = try fixture()
        let mutations: [(String, (inout PreparedTunnelCacheRecord) -> Void)] = [
            ("different account", { $0.accountUserId = "account-b" }),
            ("legacy record without owner", { $0.accountUserId = nil }),
            ("conflicting device owner", { $0.device.userId = "account-b" }),
            ("missing device id", { $0.device.id = "" }),
            ("different public key", { $0.device.publicKey = "different-public-key" }),
            ("missing public key", { $0.device.publicKey = nil }),
            ("different server key epoch", { $0.device.keyEpoch = 8 }),
            ("missing server key epoch", { $0.device.keyEpoch = nil }),
            ("invalid server key epoch", { $0.device.keyEpoch = 0 }),
            ("different local key epoch", { $0.localKeyEpoch = 8 }),
            ("missing local key epoch", { $0.localKeyEpoch = nil }),
            ("revoked device", { $0.device.status = "revoked" }),
            ("rotation required", { $0.rotationRequired = true }),
            ("different installation", { $0.device.externalDeviceId = "installation-b:de" }),
            ("missing installation", { $0.device.externalDeviceId = nil }),
            ("different assigned IP", { $0.device.assignedIpv4 = "10.8.0.3" }),
            ("missing assigned IP", { $0.device.assignedIpv4 = nil }),
            ("different location", { $0.locationId = "nl" }),
            ("different route mode", { $0.routingMode = .allExceptRu }),
            ("legacy AWG version", { $0.awgVersion = 2 }),
            ("missing profile version", { $0.profileVersion = nil }),
            ("invalid profile version", { $0.profileVersion = 0 })
        ]
        for (name, mutate) in mutations {
            var changed = original
            mutate(&changed)
            XCTAssertFalse(canReuse(changed, currentDevice: original.device), name)
        }
        XCTAssertFalse(canReuse(original, accountUserId: "account-b"))
        XCTAssertFalse(canReuse(original, accountUserId: ""))
        XCTAssertFalse(canReuse(original, installationId: "installation-b"))
    }

    func testCurrentServerDeviceReplacementCannotReuseTheOldVersion() throws {
        let cached = try fixture()
        let mutations: [(String, (inout VpnDevice) -> Void)] = [
            ("replacement device with same profile version", { $0.id = "device-b" }),
            ("different owner", { $0.userId = "account-b" }),
            ("revoked device", { $0.status = "revoked" }),
            ("different public key", { $0.publicKey = "different-public-key" }),
            ("different server epoch", { $0.keyEpoch = 8 }),
            ("different assigned IP", { $0.assignedIpv4 = "10.8.0.3/32" }),
            ("different installation", { $0.externalDeviceId = "installation-b" })
        ]
        for (name, mutate) in mutations {
            var currentDevice = cached.device
            mutate(&currentDevice)
            XCTAssertFalse(canReuse(cached, currentDevice: currentDevice), name)
        }
    }

    func testChangedLocalPublicPrivateOrEpochCannotReuseAProfile() throws {
        let cached = try fixture()
        let mutations: [(String, (inout WireGuardKeyPair) -> Void)] = [
            ("different public key", { $0.publicKey = "different-public-key" }),
            ("missing public key", { $0.publicKey = "" }),
            ("different private key", { $0.privateKey = "different-private-key" }),
            ("missing private key", { $0.privateKey = "" }),
            ("different local epoch", { $0.keyEpoch = 8 })
        ]
        for (name, mutate) in mutations {
            var changed = keyPair
            mutate(&changed)
            XCTAssertFalse(canReuse(cached, keyPair: changed), name)
        }
    }

    func testCompactUnchangedRequiresMatchingIdentityAndVersionFields() throws {
        let cached = try fixture()
        let profile = try unchangedProfile()
        XCTAssertTrue(VPNProfileCacheIdentity.confirmsUnchanged(profile, cached: cached, device: cached.device, keyPair: keyPair))
        let mutations: [(String, (inout ManagedVpnProfile) -> Void)] = [
            ("not unchanged", { $0.unchanged = false }),
            ("missing unchanged", { $0.unchanged = nil }),
            ("revoked", { $0.revoked = true }),
            ("rotation required", { $0.rotationRequired = true }),
            ("missing version", { $0.version = nil }),
            ("changed version", { $0.version = 124 }),
            ("missing device id", { $0.deviceId = nil }),
            ("changed device id", { $0.deviceId = "device-b" }),
            ("missing client public key", { $0.clientPublicKey = nil }),
            ("changed client public key", { $0.clientPublicKey = "different-public-key" }),
            ("missing client epoch", { $0.clientKeyEpoch = nil }),
            ("changed client epoch", { $0.clientKeyEpoch = 8 })
        ]
        for (name, mutate) in mutations {
            var changed = profile
            mutate(&changed)
            XCTAssertFalse(VPNProfileCacheIdentity.confirmsUnchanged(changed, cached: cached, device: cached.device, keyPair: keyPair), name)
        }
        let legacy = try JSONDecoder().decode(ManagedVpnProfile.self, from: Data(#"{"unchanged":true,"version":123,"device_id":"device-a"}"#.utf8))
        XCTAssertFalse(VPNProfileCacheIdentity.confirmsUnchanged(legacy, cached: cached, device: cached.device, keyPair: keyPair))
    }

    func testConfigAcceptsTheCurrentIPWithCIDRAndAdditionalIPv6Address() throws {
        let cached = try fixture()
        var device = cached.device
        device.assignedIpv4 = "10.8.0.2/32"
        let config = cached.config.replacingOccurrences(of: "Address = 10.8.0.2/32", with: "Address = fd00::2/128, 10.8.0.2/32")
        XCTAssertTrue(VPNProfileCacheIdentity.configMatches(config, keyPair: keyPair, device: device))
    }

    func testConfigMatchesCaseInsensitiveFieldsAndSectionsAcceptedByTheHelper() throws {
        let cached = try fixture()
        let config = cached.config
            .replacingOccurrences(of: "[Interface]", with: "[interface]")
            .replacingOccurrences(of: "[Peer]", with: "[PEER]")
            .replacingOccurrences(of: "PrivateKey", with: "pRivateKey")
            .replacingOccurrences(of: "Address", with: "aDDress")
        XCTAssertTrue(VPNProfileCacheIdentity.configMatches(config, keyPair: keyPair, device: cached.device))
    }

    func testMalformedConfigsCannotHideDuplicateKeysAddressesOrSections() throws {
        let cached = try fixture()
        let config = cached.config
        let otherPrivateKey = Data(repeating: 4, count: 32).base64EncodedString()
        let reversedSections = "[Peer]\nPublicKey = \(serverPublicKey)\nEndpoint = 203.0.113.1:443\nAllowedIPs = 0.0.0.0/0\n[Interface]\nPrivateKey = \(keyPair.privateKey)\nAddress = 10.8.0.2/32\n"
        let cases: [(String, String)] = [
            ("duplicate private key", config.replacingOccurrences(of: "Address =", with: "PrivateKey = \(keyPair.privateKey)\nAddress =")),
            ("case-variant duplicate private key", config.replacingOccurrences(of: "Address =", with: "privatekey = \(otherPrivateKey)\nAddress =")),
            ("duplicate address", config.replacingOccurrences(of: "[Peer]", with: "Address = 10.8.0.3/32\n[Peer]")),
            ("case-variant duplicate address", config.replacingOccurrences(of: "[Peer]", with: "address = 10.8.0.3/32\n[Peer]")),
            ("duplicate interface section", config + "[Interface]\n"),
            ("duplicate peer section", config + "[Peer]\n"),
            ("unknown section", config.replacingOccurrences(of: "[Peer]", with: "[Unknown]\n[Peer]")),
            ("peer before interface", reversedSections),
            ("missing interface section", config.replacingOccurrences(of: "[Interface]", with: "[Interfaces]")),
            ("missing peer section", config.replacingOccurrences(of: "[Peer]", with: "[Peers]")),
            ("private key belongs to peer", config.replacingOccurrences(of: "PrivateKey = \(keyPair.privateKey)\n", with: "").replacingOccurrences(of: "[Peer]", with: "[Peer]\nPrivateKey = \(keyPair.privateKey)")),
            ("different assigned IP", config.replacingOccurrences(of: "Address = 10.8.0.2/32", with: "Address = 10.8.0.3/32"))
        ]
        for (name, malformed) in cases {
            XCTAssertFalse(VPNProfileCacheIdentity.configMatches(malformed, keyPair: keyPair, device: cached.device), name)
        }
    }

    private var keyPair: WireGuardKeyPair {
        WireGuardKeyPair(
            privateKey: Data(repeating: 1, count: 32).base64EncodedString(),
            publicKey: Data(repeating: 2, count: 32).base64EncodedString(),
            keyEpoch: 7
        )
    }

    private var serverPublicKey: String {
        Data(repeating: 3, count: 32).base64EncodedString()
    }

    private func fixture() throws -> PreparedTunnelCacheRecord {
        let deviceJSON: [String: Any] = [
            "id": "device-a", "user_id": "account-a", "status": "active", "name": "Test Mac",
            "public_key": keyPair.publicKey, "psk_epoch": 7, "external_device_id": "installation-a",
            "assigned_ipv4": "10.8.0.2", "node_id": "de-1"
        ]
        let device = try JSONDecoder().decode(VpnDevice.self, from: JSONSerialization.data(withJSONObject: deviceJSON))
        let config = """
        [Interface]
        PrivateKey = \(keyPair.privateKey)
        Address = 10.8.0.2/32
        DNS = 1.1.1.1
        [Peer]
        PublicKey = \(serverPublicKey)
        Endpoint = 203.0.113.1:443
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25

        """
        let tunnel = PreparedTunnel(
            device: device, config: config, locationId: "de", profileVersion: 123,
            routingMode: .fullTunnel, bypassRegion: nil, bypassRangesCount: 0,
            bypassDomainsCount: 0, routingPolicyVersion: "test-policy", rotationRequired: false
        )
        return PreparedTunnelCacheRecord(tunnel: tunnel, accountUserId: "account-a", localKeyEpoch: 7)
    }

    private func unchangedProfile() throws -> ManagedVpnProfile {
        let payload: [String: Any] = [
            "unchanged": true, "version": 123, "device_id": "device-a",
            "client_public_key": keyPair.publicKey, "client_key_epoch": 7
        ]
        return try JSONDecoder().decode(ManagedVpnProfile.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func canReuse(
        _ cached: PreparedTunnelCacheRecord,
        accountUserId: String = "account-a",
        installationId: String = "installation-a",
        keyPair suppliedKeyPair: WireGuardKeyPair? = nil,
        currentDevice: VpnDevice? = nil
    ) -> Bool {
        VPNProfileCacheIdentity.canReuse(
            cached, accountUserId: accountUserId, installationId: installationId,
            keyPair: suppliedKeyPair ?? keyPair, locationId: "de", routingMode: .fullTunnel,
            currentDevice: currentDevice
        )
    }
}

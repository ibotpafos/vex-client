import Foundation
import XCTest
@testable import VEXNativeMac

final class VPNProfileCacheTests: XCTestCase {
    func testAccountsKeepSeparateProfilesForTheSameLocationAndMode() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = temporaryCache(in: directory)
        let first = try record(accountUserId: "account-a", deviceId: "device-a", config: "config-a")
        let second = try record(accountUserId: "account-b", deviceId: "device-b", config: "config-b")

        try cache.save(first, locationId: "de", routingMode: .fullTunnel)
        try cache.save(second, locationId: "de", routingMode: .fullTunnel)

        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), first)
        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-b"), second)
        XCTAssertNil(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-c"))
        XCTAssertNil(cache.load(locationId: "de", routingMode: .fullTunnel))
        XCTAssertNil(cache.load(locationId: "de", routingMode: .allExceptRu, accountUserId: "account-a"))
        XCTAssertNil(cache.load(locationId: "nl", routingMode: .fullTunnel, accountUserId: "account-a"))
    }

    func testLegacyFallbackIsPreservedWhenAnAccountProfileIsSaved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = temporaryCache(in: directory)
        let legacy = try record(accountUserId: nil, deviceId: "legacy-device", config: "legacy-config")
        try cache.save(legacy, locationId: "de", routingMode: .fullTunnel)
        let legacyURL = directory.appendingPathComponent("profiles/de-full_tunnel.json")
        let legacyData = try Data(contentsOf: legacyURL)

        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), legacy)
        let scoped = try record(accountUserId: "account-a", deviceId: "scoped-device", config: "scoped-config")
        try cache.save(scoped, locationId: "de", routingMode: .fullTunnel)

        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"), scoped)
        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-b"), legacy)
        XCTAssertEqual(cache.load(locationId: "de", routingMode: .fullTunnel), legacy)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    }

    func testAccountNamespacesPreserveCaseAndUnicodeWithoutPathCollisions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = temporaryCache(in: directory)
        let accounts = ["a/b", "a?b", "USER", "user", "../outside", "üser", "u\u{308}ser", "_-", "ō", ""]
        for (index, account) in accounts.enumerated() {
            let entry = try record(accountUserId: account, deviceId: "device-\(index)", config: "config-\(index)")
            try cache.save(entry, locationId: "de", routingMode: .fullTunnel)
        }

        for (index, account) in accounts.enumerated() {
            let loaded = try XCTUnwrap(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: account))
            XCTAssertEqual(loaded.accountUserId, account)
            XCTAssertEqual(loaded.config, "config-\(index)")
        }
        let namespaces = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("profiles"), includingPropertiesForKeys: nil)
        XCTAssertEqual(namespaces.count, accounts.count)
        XCTAssertEqual(Set(namespaces.map { $0.lastPathComponent.lowercased() }).count, accounts.count)
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for namespace in namespaces {
            XCTAssertNil(namespace.lastPathComponent.rangeOfCharacter(from: safeCharacters.inverted))
        }
    }

    func testAccountAndKeyMetadataRoundTripsWithoutLosingRotationRequirement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = temporaryCache(in: directory)
        let entry = try record(accountUserId: "account-a", deviceId: "device-a", config: "config-a", rotationRequired: true)

        try cache.save(entry, locationId: "de", routingMode: .fullTunnel)

        let loaded = try XCTUnwrap(cache.load(locationId: "de", routingMode: .fullTunnel, accountUserId: "account-a"))
        XCTAssertEqual(loaded.accountUserId, "account-a")
        XCTAssertEqual(loaded.localKeyEpoch, 7)
        XCTAssertEqual(loaded.device.userId, "account-a")
        XCTAssertEqual(loaded.device.keyEpoch, 7)
        XCTAssertEqual(loaded.device.publicKey, "client-public-key")
        XCTAssertTrue(loaded.tunnel.rotationRequired)
        XCTAssertEqual(loaded.tunnel, entry.tunnel)
    }

    func testLegacyRecordsWithoutNewMetadataStillDecode() throws {
        let entry = try record(accountUserId: nil, deviceId: "legacy-device", config: "legacy-config", rotationRequired: true)
        let encoded = try JSONEncoder().encode(entry)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "accountUserId")
        payload.removeValue(forKey: "localKeyEpoch")
        payload.removeValue(forKey: "rotationRequired")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let legacy = try JSONDecoder().decode(PreparedTunnelCacheRecord.self, from: legacyData)

        XCTAssertNil(legacy.accountUserId)
        XCTAssertNil(legacy.localKeyEpoch)
        XCTAssertNil(legacy.rotationRequired)
        XCTAssertFalse(legacy.tunnel.rotationRequired)
        XCTAssertEqual(legacy.config, entry.config)
        XCTAssertEqual(legacy.device.id, entry.device.id)
    }

    func testProfileIdentityMetadataDecodesAndLegacyResponsesRemainCompatible() throws {
        let current = Data(#"{"device_id":"device-a","client_public_key":"client-key","client_key_epoch":7}"#.utf8)
        let profile = try JSONDecoder().decode(ManagedVpnProfile.self, from: current)
        XCTAssertEqual(profile.clientPublicKey, "client-key")
        XCTAssertEqual(profile.clientKeyEpoch, 7)

        let legacyProfile = try JSONDecoder().decode(ManagedVpnProfile.self, from: Data(#"{"device_id":"device-a"}"#.utf8))
        XCTAssertNil(legacyProfile.clientPublicKey)
        XCTAssertNil(legacyProfile.clientKeyEpoch)
        let legacyDevice = try JSONDecoder().decode(VpnDevice.self, from: Data(#"{"id":"device-a"}"#.utf8))
        XCTAssertNil(legacyDevice.userId)
        XCTAssertNil(legacyDevice.keyEpoch)
    }

    func testHelperConfigUsesTheInjectedTemporaryFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = temporaryCache(in: directory)
        let config = "[Interface]\nPrivateKey = test-key\n[Peer]\nPublicKey = test-peer\n"

        try cache.writeHelperConfig(config)

        XCTAssertEqual(cache.readHelperConfig(), config)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("helper/vex.conf"), encoding: .utf8), config)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VPNProfileCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryCache(in directory: URL) -> VPNProfileCache {
        VPNProfileCache(directoryURL: directory, helperConfigURL: directory.appendingPathComponent("helper/vex.conf"))
    }

    private func record(accountUserId: String?, deviceId: String, config: String, rotationRequired: Bool = false) throws -> PreparedTunnelCacheRecord {
        var device = try JSONDecoder().decode(VpnDevice.self, from: Data(#"{"id":"placeholder"}"#.utf8))
        device.id = deviceId
        device.userId = accountUserId
        device.publicKey = "client-public-key"
        device.keyEpoch = 7
        let tunnel = PreparedTunnel(
            device: device,
            config: config,
            locationId: "de",
            profileVersion: 123,
            routingMode: .fullTunnel,
            bypassRegion: nil,
            bypassRangesCount: 0,
            bypassDomainsCount: 0,
            routingPolicyVersion: "test-policy",
            rotationRequired: rotationRequired
        )
        return PreparedTunnelCacheRecord(tunnel: tunnel, accountUserId: accountUserId, localKeyEpoch: 7)
    }
}

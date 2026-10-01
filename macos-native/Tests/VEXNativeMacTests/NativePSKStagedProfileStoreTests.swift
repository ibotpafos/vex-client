import XCTest
@testable import VEXNativeMac

final class NativePSKStagedProfileStoreTests: XCTestCase {
    private let owner = NativePushPSKEventOwner(accountID: "account-A", installationID: "install-A")!
    private let device = "11111111-1111-4111-8111-111111111111"
    private let rotation = "22222222-2222-4222-8222-222222222222"
    private func envelope(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> PSKRotationCurrentResponse {
        var value: [String: Any] = ["rotation_id": rotation, "activate": false, "current_version": 4, "profile_version": 5, "profile_digest": "sha256:" + String(repeating: "a", count: 64), "deadline_at": "2026-10-03T00:00:00Z", "profile": ["version": 5, "device_id": device, "preshared_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]]
        mutate(&value)
        return try JSONDecoder().decode(PSKRotationCurrentResponse.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testDurableOwnedInactiveStage() throws {
        let root = URL(fileURLWithPath: "/private/tmp/NativePSKStagedProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativePSKStagedProfileStore(appDataURL: root)
        let queue = NativePushPSKEventQueue(appDataURL: root)
        let value = try envelope { raw in
            var profile = raw["profile"] as! [String: Any]
            profile["authorization"] = ["algorithm": "ECDSA_P256_SHA256_DER", "key_id": "pinned-key-1", "payload_base64": "eyJ2IjoxfQ", "signature_base64": Data([0x30, 0x44, 0x02, 0x20] + Array(repeating: 1, count: 32) + [0x02, 0x20] + Array(repeating: 2, count: 32)).base64EncodedString().replacingOccurrences(of: "=", with: "")]
            raw["profile"] = profile
        }
        try store.stage(value, owner: owner, managedDeviceID: device)
        XCTAssertEqual(try NativePSKStagedProfileStore(appDataURL: root).load(owner: owner, managedDeviceID: device, rotationID: rotation)?.envelope.profile.presharedKey, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        XCTAssertEqual(try NativePSKStagedProfileStore(appDataURL: root).load(owner: owner, managedDeviceID: device, rotationID: rotation)?.envelope.profile.authorization?.keyID, "pinned-key-1")
        XCTAssertNil(try store.load(owner: NativePushPSKEventOwner(accountID: "account-B", installationID: "install-A")!, managedDeviceID: device, rotationID: rotation))
        XCTAssertNil(try store.load(owner: owner, managedDeviceID: "33333333-3333-4333-8333-333333333333", rotationID: rotation))
        XCTAssertNil(try store.load(owner: owner, managedDeviceID: device, rotationID: "44444444-4444-4444-8444-444444444444"))
        XCTAssertTrue(try queue.events(owner: owner).isEmpty) // metadata queue remains untouched
        try store.purge(owner: owner, managedDeviceID: device, rotationID: rotation)
        XCTAssertNil(try store.load(owner: owner, managedDeviceID: device, rotationID: rotation))
    }
    func testRejectsInvalidEnvelope() throws {
        let root = URL(fileURLWithPath: "/private/tmp/NativePSKStagedProfileStoreReject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativePSKStagedProfileStore(appDataURL: root)
        for edit in [{ (v: inout [String: Any]) in v["activate"] = true }, { (v: inout [String: Any]) in v["profile_digest"] = "sha256:bad" }, { (v: inout [String: Any]) in v["profile_version"] = 4 }, { (v: inout [String: Any]) in var p = v["profile"] as! [String: Any]; p["device_id"] = "other"; v["profile"] = p }] {
            XCTAssertThrowsError(try store.stage(try envelope(edit), owner: owner, managedDeviceID: device))
        }
    }
}

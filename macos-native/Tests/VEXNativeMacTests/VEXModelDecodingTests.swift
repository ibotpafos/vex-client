import XCTest
@testable import VEXNativeMac

final class VEXModelDecodingTests: XCTestCase {
    func testLocationDecodesFractionalLatencyFromApi() throws {
        let data = """
        {
          "id": "de",
          "country_code": "DE",
          "city": "Germany",
          "flag_emoji": "🇩🇪",
          "availability": "available",
          "status": "healthy",
          "healthy_nodes": 1,
          "latency_ms": 7.122
        }
        """.data(using: .utf8)!

        let location = try JSONDecoder().decode(VpnLocation.self, from: data)

        XCTAssertEqual(location.id, "de")
        XCTAssertEqual(location.displayName, "🇩🇪 Germany")
        XCTAssertEqual(location.latencyMs, 7.122)
    }

    func testStoredSessionDecodesTauriPayloadShape() throws {
        let data = """
        {
          "user": {"id": "usr_1", "email": "user@example.com", "status": "active"},
          "accessToken": "token",
          "expiresAt": "2026-06-30T00:00:00Z"
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(AuthSession.self, from: data)

        XCTAssertEqual(session.accessToken, "token")
        XCTAssertEqual(session.user.email, "user@example.com")
    }

    func testVpnDeviceDecodesClientAppVersionFromApi() throws {
        let data = """
        {
          "id": "vex_1",
          "name": "Mac",
          "status": "active",
          "protocol": "amneziawg",
          "external_device_id": "macos-test",
          "platform": "macos",
          "app_version": "0.1.42"
        }
        """.data(using: .utf8)!

        let device = try JSONDecoder().decode(VpnDevice.self, from: data)

        XCTAssertEqual(device.appVersion, "0.1.42")
    }

    func testKeychainDefaultServiceIsNativeNotLegacyTauri() {
        XCTAssertEqual(VEXKeychainStore().service, VEXKeychainStore.nativeService)
        XCTAssertNotEqual(VEXKeychainStore().service, VEXKeychainStore.legacyTauriService)
    }

    func testLegacyTauriServiceNameRemainsExplicitForSilentMigrationOnly() {
        let legacy = VEXKeychainStore(service: VEXKeychainStore.legacyTauriService)
        XCTAssertEqual(legacy.service, "app.vex.vpn.desktop.sensitive-storage")
    }
}

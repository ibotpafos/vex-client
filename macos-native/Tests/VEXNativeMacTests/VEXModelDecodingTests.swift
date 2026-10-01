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
        XCTAssertEqual(location.displayName, "🇩🇪 Германия")
        XCTAssertEqual(location.latencyMs, 7.122)
    }

    func testStoredSessionDecodesLegacyDesktopPayloadShape() throws {
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

    func testEntitlementDecodesDeviceAddonCapabilities() throws {
        let data = """
        {
          "active": true,
          "plan_id": "pro_monthly",
          "device_limit": 4,
          "base_device_limit": 3,
          "addon_device_slots": 1,
          "max_device_limit": 5,
          "can_buy_device_addon": true,
          "device_addon_price_minor": 9900,
          "device_addon_currency": "RUB",
          "active_devices": 2,
          "can_create_device": true
        }
        """.data(using: .utf8)!

        let entitlement = try JSONDecoder().decode(Entitlement.self, from: data)

        XCTAssertTrue(entitlement.hasPaidAccess)
        XCTAssertEqual(entitlement.deviceLimit, 4)
        XCTAssertEqual(entitlement.baseDeviceLimit, 3)
        XCTAssertEqual(entitlement.addonDeviceSlots, 1)
        XCTAssertEqual(entitlement.activeDevices, 2)
        XCTAssertEqual(entitlement.remainingDeviceSlots, 2)
        XCTAssertTrue(entitlement.canBuyDeviceAddon)
        XCTAssertEqual(entitlement.deviceAddonPriceMinor, 9900)
        XCTAssertEqual(entitlement.deviceAddonCurrency, "RUB")
    }

    func testEntitlementKeepsBackwardCompatibleDefaults() throws {
        let data = """
        {
          "active": true,
          "device_limit": 1,
          "active_devices": 0,
          "can_create_device": true
        }
        """.data(using: .utf8)!

        let entitlement = try JSONDecoder().decode(Entitlement.self, from: data)

        XCTAssertTrue(entitlement.vpnAccess)
        XCTAssertFalse(entitlement.canBuyDeviceAddon)
        XCTAssertEqual(entitlement.remainingDeviceSlots, 1)
    }

    func testKeychainDefaultServiceIsNativeNotLegacyDesktop() {
        XCTAssertEqual(VEXKeychainStore().service, VEXKeychainStore.nativeService)
        XCTAssertNotEqual(VEXKeychainStore().service, VEXKeychainStore.legacyDesktopService)
    }

    func testLegacyDesktopServiceNameRemainsExplicitForSilentMigrationOnly() {
        let legacy = VEXKeychainStore(service: VEXKeychainStore.legacyDesktopService)
        XCTAssertEqual(legacy.service, "app.vex.vpn.desktop.sensitive-storage")
    }
}

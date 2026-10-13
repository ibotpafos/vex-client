import XCTest
@testable import VEXNativeMac

final class AutopilotAssessmentTests: XCTestCase {
    func testSilentPeerDoesNotTriggerClientKeyRotation() {
        let service = VpnAutopilotService()
        for message in ["no_handshake: tunnel route is active but peer did not answer", "missing_peer"] {
            let result = service.assess(error: NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]))
            XCTAssertEqual(result.cause, .server)
            XCTAssertTrue(result.canFailover)
            XCTAssertFalse(result.userMessage.contains("ключ"))
        }
    }

    func testExplicitRevocationStillRequiresProfileRecovery() {
        let service = VpnAutopilotService()
        for message in ["wireguard key rotation required", "profile revoked: no_handshake", "VPN_CONFIG_INVALID"] {
            let result = service.assess(error: NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]))
            XCTAssertEqual(result.cause, .keyOrProfile)
        }
    }
}

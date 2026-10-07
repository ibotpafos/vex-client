import XCTest
@testable import VEXNativeMac

final class ClientNetworkObservationTests: XCTestCase {
    func testReferenceRequiresUnchangedNetworkDeviceSessionAndFreshness() {
        let now = Date(timeIntervalSince1970: 1_000)
        let network = ClientNetworkSnapshot(networkClass: "wifi", generation: "fixture-generation")
        let captured = CapturedClientNetwork(snapshot: network, id: "fixture-observation", deviceId: "fixture-device", accessToken: "fixture-token", capturedAt: now)
        XCTAssertTrue(captured.matches(network, device: "fixture-device", token: "fixture-token", now: now))
        XCTAssertFalse(captured.matches(ClientNetworkSnapshot(networkClass: "wifi", generation: "changed"), device: "fixture-device", token: "fixture-token", now: now))
        XCTAssertFalse(captured.matches(network, device: "other-device", token: "fixture-token", now: now))
        XCTAssertFalse(captured.matches(network, device: "fixture-device", token: "other-token", now: now))
        XCTAssertFalse(captured.matches(network, device: "fixture-device", token: "fixture-token", now: now.addingTimeInterval(6 * 60 * 60 + 1)))
        XCTAssertFalse(captured.matches(network, device: "fixture-device", token: "fixture-token", now: now.addingTimeInterval(-1)))
    }
}

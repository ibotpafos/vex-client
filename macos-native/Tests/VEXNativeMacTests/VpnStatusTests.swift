import XCTest
@testable import VEXNativeMac

final class VpnStatusTests: XCTestCase {
    func testConnectedStatusParsesTrafficAndLeakProtection() {
        let status = VpnStatus(helperResponse: "state=connected rx=161700000 tx=815400000 latest_handshake=0 leak_protection=off\n")

        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.rxBytes, 161_700_000)
        XCTAssertEqual(status.txBytes, 815_400_000)
        XCTAssertEqual(status.leakProtection, "off")
        XCTAssertEqual(status.handshakeText, "pending")
    }

    func testDisconnectedStatusWhenHelperReportsNoRouteSocketOrTraffic() {
        let status = VpnStatus(helperResponse: "state=disconnected rx=0 tx=0 latest_handshake=0 route_ok=false socket_exists=false leak_protection=off\n")

        XCTAssertEqual(status.state, .disconnected)
        XCTAssertEqual(status.rxBytes, 0)
        XCTAssertEqual(status.txBytes, 0)
    }

    func testOperationInProgressWinsOverDisconnectedSignals() {
        let status = VpnStatus(helperResponse: "operation_in_progress=true rx=0 tx=0 route_ok=false socket_exists=false\n")

        XCTAssertEqual(status.state, .connecting)
    }
}

import XCTest
@testable import VEXNativeMac

final class VpnStatusTests: XCTestCase {
    func testConnectedStatusParsesTrafficAndLeakProtection() {
        let status = VpnStatus(helperResponse: "state=connected route_ok=true rx=161700000 tx=815400000 latest_handshake=0 leak_protection=off\n")

        XCTAssertEqual(status.state, .connected)
        XCTAssertTrue(status.routeOk)
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

    func testSocketWithoutRouteIsNotConnected() {
        let status = VpnStatus(helperResponse: "state=error iface=utun7 socket_exists=true route_ok=false route_iface=utun6 rx=2048 tx=4096 latest_handshake=0\n")

        XCTAssertEqual(status.state, .disconnected)
        XCTAssertFalse(status.isUsableConnectedStatus)
        XCTAssertTrue(status.hasRouteConflict)
        XCTAssertTrue(status.hasIPv4RouteConflict)
        XCTAssertEqual(status.routeInterface, "utun6")
        XCTAssertEqual(
            status.routeConflictMessage,
            "Другой VPN удерживает системный маршрут. Трафик через VEX не идет."
        )
    }

    func testIPv6ForeignTunnelRouteWarnsWithoutBreakingIPv4ConnectedState() {
        let status = VpnStatus(helperResponse: "state=connected iface=utun6 socket_exists=true route_ok=true route_iface=utun6 ipv6_route_ok=false ipv6_route_iface=utun0 rx=2048 tx=4096 latest_handshake=0\n")

        XCTAssertEqual(status.state, .connected)
        XCTAssertTrue(status.isUsableConnectedStatus)
        XCTAssertTrue(status.hasRouteConflict)
        XCTAssertFalse(status.hasIPv4RouteConflict)
        XCTAssertTrue(status.hasIPv6RouteConflict)
        XCTAssertEqual(status.ipv6RouteInterface, "utun0")
        XCTAssertEqual(
            status.routeConflictMessage,
            "IPv6 удерживает другой VPN. VEX ведет IPv4-трафик, часть сайтов может открываться медленно."
        )
    }

    func testStaleConnectedSuccessIsHiddenWhenHelperIsDisconnected() {
        let disconnected = VpnStatus(helperResponse: "state=disconnected socket_exists=false route_ok=false rx=0 tx=0 latest_handshake=0\n")
        let connected = VpnStatus(helperResponse: "state=connected socket_exists=true route_ok=true rx=2048 tx=4096 latest_handshake=0\n")

        XCTAssertNil(VEXUserFacingText.status("VPN подключен через 🇩🇪 Germany.", respecting: disconnected))
        XCTAssertEqual(
            VEXUserFacingText.status("VPN подключен через 🇩🇪 Germany.", respecting: connected),
            "VPN подключен через 🇩🇪 Germany."
        )
    }

    func testRouteOnlyAndTransmitOnlySignalsAreNotConnected() {
        let status = VpnStatus(helperResponse: "state=connected iface=utun7 socket_exists=true route_ok=true route_iface=utun7 rx=0 tx=1313 latest_handshake=0\n")

        XCTAssertEqual(status.state, .disconnected)
        XCTAssertFalse(status.isUsableConnectedStatus)
    }

    func testStaleTransientBusyMessagesAreHiddenAfterDisconnect() {
        let status = VpnStatus(helperResponse: "state=disconnected route_ok=false socket_exists=false rx=0 tx=0 latest_handshake=0\n")

        XCTAssertNil(VEXUserFacingText.status("Отменяем подключение VPN.", respecting: status, isBusy: false))
        XCTAssertNil(VEXUserFacingText.status("Готовим VPN-профиль.", respecting: status, isBusy: false))
        XCTAssertEqual(
            VEXUserFacingText.status("Отменяем подключение VPN.", respecting: status, isBusy: true),
            "Отменяем подключение VPN."
        )
    }

    func testOperationInProgressWinsOverDisconnectedSignals() {
        let status = VpnStatus(helperResponse: "operation_in_progress=true rx=0 tx=0 route_ok=false socket_exists=false\n")

        XCTAssertEqual(status.state, .connecting)
    }
}

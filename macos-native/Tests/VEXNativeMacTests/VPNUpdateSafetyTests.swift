import XCTest
@testable import VEXNativeMac

final class VPNUpdateSafetyTests: XCTestCase {
    @MainActor
    func testInstalledFakeProviderIsFailSafeUntilItReportsIdle() {
        var snapshot: NativeVPNUpdateSafetySnapshot?
        NativeVPNUpdateSafetyProvider.install { snapshot }

        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetyProvider.currentSnapshot()
        ))

        snapshot = NativeVPNUpdateSafetySnapshot(
            helperState: .disconnected,
            hasManagedNetworkState: false,
            helperIsBusy: false,
            hasActiveTunnelRoute: false
        )
        XCTAssertFalse(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetyProvider.currentSnapshot()
        ))
    }

    func testUnknownSnapshotDefersRelaunch() {
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(nil))
    }

    func testConnectedAndTransitioningStatesDeferRelaunch() {
        for state in [VpnConnectionState.connected, .connecting, .disconnecting] {
            XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
                NativeVPNUpdateSafetySnapshot(
                    helperState: state,
                    hasManagedNetworkState: true,
                    helperIsBusy: false,
                    hasActiveTunnelRoute: false
                )
            ))
        }
    }

    func testManagedStateAndBusyHelperDeferEvenWhenStatusLooksDisconnected() {
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetySnapshot(
                helperState: .disconnected,
                hasManagedNetworkState: true,
                helperIsBusy: false,
                hasActiveTunnelRoute: false
            )
        ))
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetySnapshot(
                helperState: .disconnected,
                hasManagedNetworkState: false,
                helperIsBusy: true,
                hasActiveTunnelRoute: false
            )
        ))
    }

    func testOtherActiveTunnelRouteDefersRelaunch() {
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetySnapshot(
                helperState: .disconnected,
                hasManagedNetworkState: false,
                helperIsBusy: false,
                hasActiveTunnelRoute: true
            )
        ))
    }

    func testKnownTunnelInterfaceClassifierAcceptsOnlyNumericTunnelSuffixes() {
        for interface in ["utun0", "tun12", "tap3", "ppp4", "ipsec5", " IPSEC6 "] {
            XCTAssertTrue(NativeVPNUpdateSafetyPolicy.hasKnownTunnelInterface(interface), interface)
        }
        for interface in [nil, "", "en0", "bridge0", "utun", "utunx", "tap-1", "ipsec0x"] {
            XCTAssertFalse(NativeVPNUpdateSafetyPolicy.hasKnownTunnelInterface(interface), interface ?? "nil")
        }
    }

    func testOnlyKnownIdleDisconnectedStatePermitsRelaunch() {
        XCTAssertFalse(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(
            NativeVPNUpdateSafetySnapshot(
                helperState: .disconnected,
                hasManagedNetworkState: false,
                helperIsBusy: false,
                hasActiveTunnelRoute: false
            )
        ))
    }
}

import XCTest
@testable import VEXNativeMac

final class LocationSelectionSafetyTests: XCTestCase {
    private func location(
        _ id: String,
        availability: String = "available",
        status: String = "healthy",
        healthyNodes: Int = 1,
        awg3Nodes: Int? = 1,
        latencyMs: Double? = 10
    ) -> VpnLocation {
        VpnLocation(
            id: id,
            countryCode: "DE",
            city: id,
            flagEmoji: nil,
            availability: availability,
            status: status,
            healthyNodes: healthyNodes,
            awg3Nodes: awg3Nodes,
            latencyMs: latencyMs
        )
    }

    func testManualSelectionFailsClosedForEmptyStaleAndUnselectableIDs() {
        let good = location("good")
        let maintenance = location("maintenance", availability: "maintenance")

        XCTAssertNil(VpnLocationSelection.targetID(locations: [good], selectedID: "", automatic: false))
        XCTAssertNil(VpnLocationSelection.targetID(locations: [good], selectedID: "stale", automatic: false))
        XCTAssertNil(VpnLocationSelection.targetID(locations: [good, maintenance], selectedID: maintenance.id, automatic: false))
        XCTAssertEqual(VpnLocationSelection.targetID(locations: [good], selectedID: good.id, automatic: false), good.id)
    }

    func testAutomaticSelectionSkipsUnpublishedUnhealthyAndAwg3IncompatibleLocations() {
        let selected = location("selected", latencyMs: 12)
        let hidden = location("hidden", availability: "hidden", latencyMs: 1)
        let maintenance = location("maintenance", availability: "maintenance", latencyMs: 2)
        let unhealthy = location("unhealthy", healthyNodes: 0, latencyMs: 3)
        let awg2Only = location("awg2", awg3Nodes: 0, latencyMs: 4)

        XCTAssertEqual(
            VpnLocationSelection.targetID(
                locations: [hidden, maintenance, unhealthy, awg2Only, selected],
                selectedID: "stale",
                automatic: true
            ),
            selected.id
        )
    }

    func testAutomaticSelectionSortsInvalidLatencyLastThenStableID() {
        let invalid = location("invalid", latencyMs: .nan)
        let negative = location("negative", latencyMs: -1)
        let slow = location("slow", latencyMs: 40)
        let fastB = location("b", latencyMs: 5)
        let fastA = location("a", latencyMs: 5)

        XCTAssertEqual(
            VpnLocationSelection.targetID(
                locations: [invalid, negative, slow, fastB, fastA],
                selectedID: "",
                automatic: true
            ),
            fastA.id
        )
    }

    func testFallbackRejectsExcludedAndUnselectableLocations() {
        let active = location("DE")
        let maintenance = location("maintenance", availability: "maintenance", latencyMs: 1)
        let healthy = location("nl", latencyMs: 9)

        XCTAssertEqual(
            VpnLocationSelection.fallback(locations: [active, maintenance, healthy], excluding: " de ")?.id,
            healthy.id
        )
        XCTAssertNil(VpnLocationSelection.fallback(locations: [active, maintenance], excluding: active.id))
    }

    func testDeviceRemovalFailsClosedUntilConfirmedIdleAndNeverRemovesActiveDevice() {
        XCTAssertFalse(DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: false, helperBusy: false, vpnBusy: false, activeDeviceID: nil, requestedDeviceID: "device-1"
        ))
        XCTAssertFalse(DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: true, helperBusy: true, vpnBusy: false, activeDeviceID: nil, requestedDeviceID: "device-1"
        ))
        XCTAssertFalse(DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: true, helperBusy: false, vpnBusy: true, activeDeviceID: nil, requestedDeviceID: "device-1"
        ))
        XCTAssertFalse(DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: true, helperBusy: false, vpnBusy: false, activeDeviceID: "device-1", requestedDeviceID: "device-1"
        ))
        XCTAssertTrue(DeviceRemovalSafety.permitsRemoval(
            confirmedIdle: true, helperBusy: false, vpnBusy: false, activeDeviceID: "device-1", requestedDeviceID: "device-2"
        ))
    }

    func testUpdateRelaunchDefersForUnknownConnectedTransitionBusyManagedOrOtherRoute() {
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(nil))
        for state in [VpnConnectionState.connected, .connecting, .disconnecting] {
            XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(
                helperState: state, hasManagedNetworkState: true, helperIsBusy: false, hasActiveTunnelRoute: false
            )))
        }
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(
            helperState: .disconnected, hasManagedNetworkState: true, helperIsBusy: false, hasActiveTunnelRoute: false
        )))
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(
            helperState: .disconnected, hasManagedNetworkState: false, helperIsBusy: true, hasActiveTunnelRoute: false
        )))
        XCTAssertTrue(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(
            helperState: .disconnected, hasManagedNetworkState: false, helperIsBusy: false, hasActiveTunnelRoute: true
        )))
        XCTAssertFalse(NativeVPNUpdateSafetyPolicy.shouldDeferRelaunch(.init(
            helperState: .disconnected, hasManagedNetworkState: false, helperIsBusy: false, hasActiveTunnelRoute: false
        )))
    }
}

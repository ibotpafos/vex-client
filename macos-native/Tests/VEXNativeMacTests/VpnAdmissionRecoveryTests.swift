import XCTest
@testable import VEXNativeMac

@MainActor
final class VpnAdmissionRecoveryTests: XCTestCase {
    func testFreshResolutionAndNativeRecoveryBoundaries() async throws {
        try await VpnAdmissionRecoveryScenarios.run()
    }
}

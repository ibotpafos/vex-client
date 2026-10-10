import XCTest
@testable import VEXNativeMac

final class VpnRecoveryIntentTests: XCTestCase {
    func testConnectedRecoveryRequiresTheObservedAccountOperationAndIntent() {
        let intent = VpnRecoveryIntent(userId: "account-a", accountGeneration: 4, operationGeneration: 17)
        XCTAssertTrue(intent.matchesConnectedIntent(userId: "account-a", accountGeneration: 4,
            operationGeneration: 17, wantsConnected: true))
        for (user, account, operation, wantsConnected) in [
            ("account-b", 4, 17, true), ("account-a", 5, 17, true),
            ("account-a", 4, 18, true), ("account-a", 4, 17, false),
        ] {
            XCTAssertFalse(intent.matchesConnectedIntent(userId: user, accountGeneration: account,
                operationGeneration: operation, wantsConnected: wantsConnected))
        }
        XCTAssertFalse(intent.matchesConnectedIntent(userId: nil, accountGeneration: 4,
            operationGeneration: 17, wantsConnected: true))
    }

    func testRecoveryReconnectRequiresOnlyItsOwnCompletedDisconnect() {
        let intent = VpnRecoveryIntent(userId: "account-a", accountGeneration: 4, operationGeneration: 17)
        XCTAssertTrue(intent.matchesRecoveryDisconnect(userId: "account-a", accountGeneration: 4,
            operationGeneration: 18, wantsConnected: false))
        for (user, account, operation, wantsConnected) in [
            ("account-b", 4, 18, false), ("account-a", 5, 18, false),
            ("account-a", 4, 17, false), ("account-a", 4, 19, false),
            ("account-a", 4, 18, true),
        ] {
            XCTAssertFalse(intent.matchesRecoveryDisconnect(userId: user, accountGeneration: account,
                operationGeneration: operation, wantsConnected: wantsConnected))
        }
    }

    func testOldCompletionCannotReleaseNewBusyOwner() {
        var ownership = VpnOperationOwnership()
        let old = ownership.begin()
        ownership.invalidate()
        let replacement = ownership.begin()
        XCTAssertFalse(ownership.finish(old))
        XCTAssertTrue(ownership.owns(replacement))
        XCTAssertTrue(ownership.finish(replacement))
        XCTAssertFalse(ownership.owns(replacement))
    }

    func testSwitchGenerationChangesDoNotChangeBusyOwnership() {
        var ownership = VpnOperationOwnership()
        let owner = ownership.begin()
        let intent = VpnRecoveryIntent(userId: "account-a", accountGeneration: 4, operationGeneration: 17)
        XCTAssertFalse(intent.matchesConnectedIntent(userId: "account-a", accountGeneration: 4,
            operationGeneration: 18, wantsConnected: true))
        XCTAssertTrue(ownership.owns(owner))
        XCTAssertTrue(ownership.finish(owner))
        XCTAssertFalse(ownership.finish(owner))
    }
}

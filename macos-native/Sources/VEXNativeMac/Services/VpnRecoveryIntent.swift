import Foundation

// A watchdog observes existing user intent. It may only replace that tunnel
// while the account and operation it observed still own the connection.
struct VpnRecoveryIntent {
    let userId: String
    let accountGeneration: Int
    let operationGeneration: Int

    func matchesConnectedIntent(
        userId: String?, accountGeneration: Int, operationGeneration: Int,
        wantsConnected: Bool
    ) -> Bool {
        userId == self.userId && accountGeneration == self.accountGeneration
            && operationGeneration == self.operationGeneration && wantsConnected
    }

    // disconnectVPN advances the operation once and temporarily requests off.
    // Any additional stop, start or account change belongs to a newer caller.
    func matchesRecoveryDisconnect(
        userId: String?, accountGeneration: Int, operationGeneration: Int,
        wantsConnected: Bool
    ) -> Bool {
        userId == self.userId && accountGeneration == self.accountGeneration
            && operationGeneration == self.operationGeneration + 1 && !wantsConnected
    }
}

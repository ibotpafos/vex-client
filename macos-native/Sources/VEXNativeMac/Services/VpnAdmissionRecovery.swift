import Foundation

/// The fresh-profile boundary shared by the app and executable orchestration tests.
@MainActor
enum VpnAdmissionRecovery {
    static func retryFreshProfile<T>(
        attempt: () async throws -> T,
        failover: (Error) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt()
        } catch {
            // A fresh-profile admission rejection must not inherit the initial
            // transport assessment or authorize another location/activation.
            if error.localizedDescription.contains("VPN_CONFIG_INVALID") { throw error }
            return try await failover(error)
        }
    }
}

import Foundation

/// The fresh-profile boundary shared by the app and executable orchestration tests.
@MainActor
enum VpnAdmissionRecovery {
    static func retryFreshProfile<Profile, T>(
        resolve: () async throws -> Profile,
        connect: (Profile) async throws -> T,
        failover: (Error) async throws -> T
    ) async throws -> T {
        // Resolution may already issue a profile or reconcile its peer. An
        // uncertain response cannot authorize another location's issuance.
        let profile = try await resolve()
        do {
            return try await connect(profile)
        } catch {
            // A fresh-profile admission rejection must not inherit the initial
            // transport assessment or authorize another location/activation.
            if error is HelperDisconnectError || error.localizedDescription.contains("VPN_CONFIG_INVALID") { throw error }
            return try await failover(error)
        }
    }
}

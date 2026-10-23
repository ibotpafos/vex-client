import Foundation

@main
struct RecoveryHarness {
    @MainActor
    static func main() async throws {
        try await VpnAdmissionRecoveryScenarios.run()
    }
}

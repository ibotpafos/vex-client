import Foundation

/// Explicit fixture executable for CLT hosts without XCTest. Never starts the app.
@main
struct VEXAPIContractProbe {
    static func main() async {
        let scenarios: [(String, () async throws -> Void)] = [
            ("GET redirects", { try await APIContractScenarios.redirects(method: "GET") }),
            ("POST redirects", { try await APIContractScenarios.redirects(method: "POST") }),
            ("stalled body deadline", { try await APIContractScenarios.bodyDeadline() }),
            ("stalled body cancellation", { try await APIContractScenarios.bodyCancellation() }),
            ("error bodies", { try await APIContractScenarios.errorBodies() }),
            ("maintenance classification", { try await APIContractScenarios.maintenanceClassification() }),
        ]
        var failures = 0
        for (name, run) in scenarios {
            do { try await run(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: " + name + ": " + String(describing: error)) }
        }
        if failures > 0 { exit(1) }
        print("NATIVE_API_CONTRACT_PROBE=passed scenarios=\(scenarios.count)")
    }
}

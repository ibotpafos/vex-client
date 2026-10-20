import Foundation

/// Explicit fixture executable for CLT hosts without XCTest. Never starts the app.
@main
struct VEXAPIContractProbe {
    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    static func main() async {
        let scenarios: [(String, () async throws -> Void)] = [
            ("GET redirects", { try await APIContractScenarios.redirects(method: "GET") }),
            ("POST redirects", { try await APIContractScenarios.redirects(method: "POST") }),
            ("stalled body deadline", { try await APIContractScenarios.bodyDeadline() }),
            ("stalled body cancellation", { try await APIContractScenarios.bodyCancellation() }),
            ("error bodies", { try await APIContractScenarios.errorBodies() }),
            ("API base URL configuration", { try await APIContractScenarios.baseURLConfiguration() }),
            ("invalid API base URLs", { try await APIContractScenarios.invalidBaseURLs() }),
            ("maintenance classification", { try await APIContractScenarios.maintenanceClassification() }),
        ]
        var failures = 0
        for (name, run) in scenarios {
            report("RUN: " + name)
            do { try await run(); report("PASS: " + name) }
            catch { failures += 1; report("FAIL: " + name + ": " + String(describing: error)) }
        }
        if failures > 0 { exit(1) }
        report("NATIVE_API_CONTRACT_PROBE=passed scenarios=\(scenarios.count)")
    }
}

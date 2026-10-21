import Foundation

/// Explicit fixture executable for CLT hosts without XCTest. Never starts the app.
@main
struct VEXAPIContractProbe {
    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    static func main() async {
        let scenarios: [(String, () async throws -> Void)] = [
            ("app update metadata", { try await APIContractScenarios.appUpdateMetadata() }),
            ("successful JSON body classification", { try await APIContractScenarios.successfulBodyDecoding() }),
            ("successful body parent cancellation", { try await APIContractScenarios.successfulBodyCancellation() }),
            ("oversized SSE reconnect", { try await APIContractScenarios.oversizedRealtimeReconnect(invalidMetadata: false) }),
            ("rejected SSE metadata retains cursor", { try await APIContractScenarios.oversizedRealtimeReconnect(invalidMetadata: true) }),
            ("location capability contract", { try await APIContractScenarios.locationCapabilities() }),
            ("GET redirects", { try await APIContractScenarios.redirects(method: "GET") }),
            ("POST redirects", { try await APIContractScenarios.redirects(method: "POST") }),
            ("SSE redirects", { try await APIContractScenarios.realtimeRedirects() }),
            ("SSE stop from status", { try await APIContractScenarios.realtimeStop(fromEvent: false) }),
            ("SSE stop from event", { try await APIContractScenarios.realtimeStop(fromEvent: true) }),
            ("SSE unauthorized", { try await APIContractScenarios.realtimeUnauthorized() }),
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

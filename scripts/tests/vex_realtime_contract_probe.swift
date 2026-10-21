import Foundation

/// Minimal production SSE closure for CLT hosts without XCTest or AppKit.
@main
struct VEXRealtimeContractProbe {
    static func main() async {
        do {
            try await RealtimeFramingScenarios.oversizedRealtimeReconnect(invalidMetadata: false)
            print("PASS: oversized SSE reconnect")
            try await RealtimeFramingScenarios.oversizedRealtimeReconnect(invalidMetadata: true)
            print("PASS: rejected SSE metadata retains cursor")
            print("NATIVE_REALTIME_CONTRACT_PROBE=passed scenarios=2")
        } catch {
            print("FAIL: minimal realtime contract: " + String(describing: error))
            exit(1)
        }
    }
}

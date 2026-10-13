import Foundation

@main
struct RecoveryHarness {
    @MainActor
    static func main() async throws {
        let transport = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "handshake timeout"])
        for admissionRejected in [true, false] {
            let admission = NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "VPN_CONFIG_INVALID: fresh profile"])
            var calls = [String]()
            do {
                do { calls.append("connect:initial"); throw transport }
                catch {
                    let result = try await VpnAdmissionRecovery.retryFreshProfile {
                        calls.append("resolve:fresh")
                        calls.append("connect:fresh")
                        throw admissionRejected ? admission : transport
                    } failover: { error -> String in
                        calls.append("select:fallback")
                        calls.append("resolve:fallback")
                        calls.append("connect:fallback")
                        return "connected"
                    }
                    precondition(!admissionRejected && result == "connected", "admission escaped into failover")
                }
            } catch {
                precondition(admissionRejected && error as NSError === admission, "original admission error was lost")
            }
            let expected = ["connect:initial", "resolve:fresh", "connect:fresh"] + (admissionRejected ? [] : ["select:fallback", "resolve:fallback", "connect:fallback"])
            precondition(calls == expected, "unexpected recovery side effects")
            print(admissionRejected ? "FRESH_ADMISSION=PROPAGATED; CONNECTS=2; FALLBACK_SELECTION_RESOLUTION_CONNECT_CLEANUP=0" : "FRESH_TRANSPORT=FAILOVER_ALLOWED; CONNECTS=3")
        }
        var selectedFallback = false
        do {
            _ = try await VpnAdmissionRecovery.retryFreshProfile {
                throw HelperDisconnectError.unconfirmed
            } failover: { _ -> String in
                selectedFallback = true
                return "unexpected"
            }
            preconditionFailure("unconfirmed stop escaped into another connection")
        } catch is HelperDisconnectError {
            precondition(!selectedFallback, "unconfirmed teardown selected a fallback")
        }
        print("UNCONFIRMED_STOP=PROPAGATED; FALLBACK_SELECTION_RESOLUTION_CONNECT=0")
    }
}

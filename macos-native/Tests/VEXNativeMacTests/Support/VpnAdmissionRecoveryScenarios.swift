import Foundation
#if !VEX_ADMISSION_STANDALONE
@testable import VEXNativeMac
#endif

// One set of orchestration cases for XCTest and the no-helper CLI harness.
@MainActor
enum VpnAdmissionRecoveryScenarios {
    static func run() async throws {
        let transport = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "handshake timeout"])
        for admissionRejected in [true, false] {
            let admission = NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "VPN_CONFIG_INVALID: fresh profile"])
            var calls = [String]()
            do {
                do { calls.append("connect:initial"); throw transport }
                catch {
                    let result = try await VpnAdmissionRecovery.retryFreshProfile(resolve: {
                        calls.append("resolve:fresh")
                        return "fresh"
                    }, connect: { profile in
                        precondition(profile == "fresh", "resolved profile was replaced")
                        calls.append("connect:fresh")
                        throw admissionRejected ? admission : transport
                    }) { error -> String in
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
            _ = try await VpnAdmissionRecovery.retryFreshProfile(resolve: { "fresh" }, connect: { _ in
                throw HelperDisconnectError.unconfirmed
            }) { _ -> String in
                selectedFallback = true
                return "unexpected"
            }
            preconditionFailure("unconfirmed stop escaped into another connection")
        } catch is HelperDisconnectError {
            precondition(!selectedFallback, "unconfirmed teardown selected a fallback")
        }
        print("UNCONFIRMED_STOP=PROPAGATED; FALLBACK_SELECTION_RESOLUTION_CONNECT=0")

        for kind in ["network", "http503", "decode", "cancel"] {
            let failure: Error = kind == "cancel" ? CancellationError() : NSError(domain: "fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: kind])
            var issuance = 0, connects = 0, failovers = 0
            do {
                _ = try await VpnAdmissionRecovery.retryFreshProfile(resolve: { () -> String in
                    issuance += 1
                    throw failure
                }, connect: { _ -> String in
                    connects += 1
                    return "unexpected"
                }) { _ -> String in
                    failovers += 1
                    return "unexpected"
                }
                preconditionFailure("uncertain resolution escaped into native/failover")
            } catch {
                if kind == "cancel" { precondition(error is CancellationError) }
                else { precondition(error as NSError === failure as NSError, "resolution error changed") }
                precondition(issuance == 1 && connects == 0 && failovers == 0, "resolution authorized another issuance")
            }
            print("FRESH_RESOLUTION_" + kind + "=PROPAGATED; ISSUANCE=1; NATIVE_FAILOVER=0")
        }
        var failovers = 0
        let connected = try await VpnAdmissionRecovery.retryFreshProfile(resolve: { 42 }, connect: { profile in
            precondition(profile == 42)
            return "connected"
        }) { _ -> String in
            failovers += 1
            return "unexpected"
        }
        precondition(connected == "connected" && failovers == 0)
        print("FRESH_SUCCESS=CONNECTED; FAILOVER=0")
    }
}

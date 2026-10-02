#!/usr/bin/env python3
"""Run the production app coordinator with inert RPC and config-write ports.

The optional source root supports identical baseline/modified/rollback inputs.
No application, installed helper, route, DNS, PF, or network service is used.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
SOURCE = ROOT / "macos-native/Sources/VEXNativeMac/Services/NativeProtectedReplacementCoordinator.swift"
if not SOURCE.is_file():
    print("protected_coordinator present=false failures=1 live_network_commands=0")
    raise SystemExit(1)

HARNESS = r'''
import Foundation
enum ProbeError: Error { case injected }
@MainActor final class Wire {
    let source = NativeProtectedReplacementCoordinator.digest("source")
    let candidate = NativeProtectedReplacementCoordinator.digest("candidate")
    let owner = NativeProtectedReplacementCoordinator.digest("owner")
    let id = "E63DCEBD-109A-4C45-A23C-3F32BF42597A"
    var mode = "success", current = true, journal = false, committed = false
    var staged = 0, restored = 0, waits = 0, polls = 0
    var calls: [String] = []
    var onReady: (() -> Void)?
    var metadata: String { "transaction_id=\(id) source_sha256=\(source) candidate_sha256=\(candidate) owner_token_sha256=\(owner)" }
    func send(_ command: String, _ timeout: Int) async throws -> String {
        let verb = String(command.split(separator: " ").first!)
        calls.append(verb)
        switch verb {
        case "protected-snapshot":
            if mode == "stale-snapshot" { current = false }
            if mode == "malformed" { return "protected_protocol=1" }
            if mode == "duplicate" { return "protected_protocol=1 protected_protocol=1\n" }
            if mode == "foreign" { return "protected_protocol=1 recovery_pending=false source_sha256=\(candidate) owner_token_sha256=\(owner) transaction_id=\(id)\n" }
            if mode == "existing-journal" { return "protected_protocol=1 recovery_pending=true \(metadata)\n" }
            if journal { return "protected_protocol=1 recovery_pending=true \(metadata)\n" }
            return "protected_protocol=1 recovery_pending=false source_sha256=\(committed ? candidate : source) owner_token_sha256=\(owner) transaction_id=\(id)\n"
        case "protected-replace":
            guard command == verb + " " + metadata else { throw ProbeError.injected }
            journal = true
            if mode == "replace-lost" { throw ProbeError.injected }
            if mode == "stale-ready" { current = false }
            onReady?()
            return "ready transaction_id=\(id) candidate_sha256=\(mode == "wrong-ready" ? source : candidate)\n"
        case "protected-commit":
            guard command == verb + " " + metadata else { throw ProbeError.injected }
            polls += 1
            if ["timeout", "recovery-failed", "stale-wait"].contains(mode) || (mode == "wait-once" && polls == 1) {
                return "error: protected replacement awaiting fresh handshake\n"
            }
            journal = false; committed = true
            if mode == "commit-lost" { throw ProbeError.injected }
            if mode == "stale-commit" { current = false }
            return "committed transaction_id=\(id) candidate_sha256=\(candidate) latest_handshake=100\n"
        case "protected-recover":
            guard command == verb + " " + metadata else { throw ProbeError.injected }
            if mode == "recovery-failed" { throw ProbeError.injected }
            journal = false
            return "recovered transaction_id=\(id)\n"
        default:
            // This fixture has no ordinary up/down/installer/network port.
            throw ProbeError.injected
        }
    }
    var dependencies: NativeProtectedReplacementCoordinator.Dependencies {
        .init(isCurrent: { self.current }, send: { try await self.send($0, $1) },
              stageCandidate: {
                  if self.mode == "stage-failed" { throw ProbeError.injected }
                  self.staged += 1
                  if self.mode == "stale-stage" { self.current = false }
              }, restoreSource: { self.restored += 1 }, wait: {
                  self.waits += 1
                  if self.mode == "stale-wait" { self.current = false }
              })
    }
}
@main struct Main {
    @MainActor static func main() async {
        var cases = 0, failures = 0
        func check(_ name: String, _ passed: Bool) {
            cases += 1; if !passed { failures += 1 }
            print("protected_coordinator \(name)=\(passed ? "PASS" : "FAIL")")
        }
        for mode in ["success", "wait-once"] {
            let w = Wire(); w.mode = mode; let c = NativeProtectedReplacementCoordinator()
            do {
                let receipt = try await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
                check(mode, receipt.transactionID == w.id && receipt.candidateSHA256 == w.candidate && receipt.latestHandshake == 100 && w.staged == 1 && w.restored == 0 && !c.hasPendingTransaction && w.polls == (mode == "success" ? 1 : 2))
            } catch { check(mode, false) }
        }
        for mode in ["malformed", "duplicate", "foreign", "existing-journal", "stale-snapshot", "stage-failed", "stale-stage"] {
            let w = Wire(); w.mode = mode; let c = NativeProtectedReplacementCoordinator()
            do {
                _ = try await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
                check(mode, false)
            } catch {
                check(mode, w.calls == ["protected-snapshot"] && w.staged == (mode == "stale-stage" ? 1 : 0) && w.restored == 0 && !c.hasPendingTransaction)
            }
        }
        for mode in ["replace-lost", "wrong-ready", "timeout"] {
            let w = Wire(); w.mode = mode; let c = NativeProtectedReplacementCoordinator()
            do {
                _ = try await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
                check(mode, false)
            } catch NativeProtectedReplacementCoordinator.Failure.sourceRestored {
                check(mode, w.staged == 1 && w.restored == 1 && !c.hasPendingTransaction && !w.journal && w.calls.last == "protected-recover" && (mode != "timeout" || w.polls == 40))
            } catch { check(mode, false) }
        }
        for mode in ["stale-ready", "stale-wait", "stale-commit", "commit-lost"] {
            let w = Wire(); w.mode = mode; let c = NativeProtectedReplacementCoordinator()
            do {
                _ = try await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
                check(mode, false)
            } catch {
                check(mode, w.staged == 1 && w.restored == 0 && c.hasPendingTransaction && !w.calls.contains("protected-recover"))
            }
        }
        do {
            let w = Wire(); w.mode = "recovery-failed"; let c = NativeProtectedReplacementCoordinator()
            _ = try? await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
            let retained = c.hasPendingTransaction && w.journal && w.restored == 0
            w.mode = "success"
            do {
                _ = try await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
                check("retry-only-recovers", false)
            } catch NativeProtectedReplacementCoordinator.Failure.sourceRestored {
                check("retry-only-recovers", retained && w.staged == 1 && w.restored == 1 && !c.hasPendingTransaction && w.calls.filter { $0 == "protected-replace" }.count == 1)
            } catch { check("retry-only-recovers", false) }
        }
        do {
            let w = Wire(); let c = NativeProtectedReplacementCoordinator()
            var task: Task<Void, Never>?
            w.onReady = { task?.cancel() }
            task = Task { @MainActor in
                _ = try? await c.replace(sourceSHA256: w.source, candidateSHA256: w.candidate, dependencies: w.dependencies)
            }
            await task?.value
            check("cancel-keeps-recovery", c.hasPendingTransaction && w.journal && w.restored == 0 && w.calls == ["protected-snapshot", "protected-replace"])
        }
        print("protected_coordinator_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

scratch = Path(os.environ.get("TMPDIR", "/tmp")).resolve()
with tempfile.TemporaryDirectory(prefix="protected-coordinator-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(HARNESS)
    subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(SOURCE), str(directory / "main.swift"), "-o", str(directory / "probe")],
                   check=True, timeout=180)
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe")], timeout=60).returncode)

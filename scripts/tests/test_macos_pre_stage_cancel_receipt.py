#!/usr/bin/env python3
"""Actual root cancellation WAL, Runtime and file custody; inert physical ports.

The frozen evaluator takes the same root for B/M/R. An absent cancellation-WAL
contract is one diagnostic, not an executed failing branch. IO fault callbacks
model process boundaries, not real power-loss/fsync or installed-helper tests.
"""
import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
contract = CORE / "ProtectedPreStageConsent.swift"
if not contract.is_file() or "struct ProtectedPreStageCancellationReceipt" not in contract.read_text():
    print("pre_stage_cancel_receipt contract=ABSENT (one diagnostic; missing runtime branches NOT executed)")
    print("pre_stage_cancel_receipt_matrix cases=1 failures=1 live_network_commands=0")
    raise SystemExit(1)


def literal(path, name):
    tree = ast.parse(path.read_text())
    return next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))


# Reuse the C36 fixture construction, not its runner. These sibling evaluator
# bytes are frozen alongside this file for every source root.
fixture = Path(__file__).with_name("test_macos_protected_pre_stage_consent.py")
setup = fixture.read_text().split("HARNESS =", 1)[0]
scope = {"__file__": str(fixture), "__name__": "cancel_receipt_fixture"}
exec(compile(setup, str(fixture), "exec"), scope)
prefix = scope["prefix"]
prefix = prefix.replace("var beforeRemove: ((String) throws -> Void)?",
                        "var beforeRemove: ((String) throws -> Void)?; var afterRemove: ((String) throws -> Void)?")
prefix = prefix.replace("data.removeValue(forKey: path) }", "data.removeValue(forKey: path); try afterRemove?(path) }")
HARNESS = literal(fixture, "HARNESS").split("Task {", 1)[0] + r'''
let cancelPath = paths.helperDirectory + "/protected-pre-stage-cancel-receipt.state"
func proof(_ p: PreFixture) throws -> ProtectedPreStageCancellationReceipt {
    try ProtectedPreStageCancellationReceipt.decode(p.f.files.data[cancelPath]!)
}
func physical(_ p: PreFixture) -> [Int] {
    [p.f.runner.up, p.f.runner.down, p.f.pf.updates, p.f.pf.enables, p.f.pf.disables]
}
func cancelACK(_ p: PreFixture) -> String { "stage-cancelled transaction_id=\(p.transaction)\n" }
Task {
    var cases = 0, failures = 0
    var names = Set<String>()
    func test(_ name: String, _ body: () async throws -> Void) async {
        cases += 1
        do {
            try check(names.insert(name).inserted, "unique case")
            try await body(); print("pre_stage_cancel_receipt \(name)=PASS")
        } catch { failures += 1; print("pre_stage_cancel_receipt \(name)=FAIL \(error.localizedDescription)") }
    }
    await test("root-WAL-readback-before-consent-delete-and-compatible-ACK") {
        let p = try PreFixture(); try await p.authorize()
        let consent = p.f.files.data[stagePath]!, owner = p.f.files.data[paths.ownerSessionPath]
        var removed = false
        p.f.files.beforeRemove = { path in
            if path == stagePath {
                let r = try proof(p)
                try check(r.consentSHA256 == digest(consent) && r.consent.uid == 501 && r.evidenceKind == "source",
                    "exact original owner proof before removal")
                try check(p.f.files.modes[cancelPath] == 0o600 && r.encoded() == p.f.files.data[cancelPath], "private canonical readback")
                removed = true
            }
        }
        try check(await p.send("protected-cancel-stage", input: p.input) == cancelACK(p) && removed, "ACK after WAL and delete")
        try check(p.f.files.data[stagePath] == nil && p.f.files.data[paths.ownerSessionPath] == owner,
            "only consent deleted, no owner write")
        let text = p.f.files.data[cancelPath]!
        try check(!text.contains(capability) && !text.contains("PrivateKey") && !text.contains("PresharedKey"), "no raw secrets in proof")
        try check(!HelperStateStore(fileSystem: p.f.files, paths: paths).protectedPreStageConsentPending, "completed WAL is inert")
        try p.untouched()
    }
    await test("lost-ACK-helper-restart-after-expiry-replays-exact-proof-no-TTL-renewal") {
        let p = try PreFixture(); try await p.authorize()
        _ = await p.send("protected-cancel-stage", input: p.input) // first response intentionally discarded
        let saved = p.f.files.data[cancelPath]!, r = try proof(p)
        Clock.shared.seconds += 121; p.restart()
        p.f.files.beforeWrite = { path, _ in if path != paths.operationLockPath { throw HelperError.io("retry must not write authority") } }
        p.f.files.beforeRemove = { path in if path != paths.operationLockPath { throw HelperError.io("retry must not remove absent consent") } }
        try check(await p.send("protected-cancel-stage", input: p.input) == cancelACK(p), "exact original live-owner retry")
        try check(p.f.files.data[cancelPath] == saved && r.consent.expiresAt == 1_800_000_120, "proof and TTL never renewed")
        try p.untouched()
    }
    for kind in ["proof-before-write", "proof-after-rename", "proof-readback", "proof-unknown-readback", "proof-mismatch-readback",
                 "consent-before-remove", "consent-after-remove", "consent-unknown-after-remove", "identity-after-proof",
                 "identity-before-remove", "identity-after-remove", "proof-corrupt-after-remove"] {
        await test("IO-boundary-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            let consent = p.f.files.data[stagePath]!
            if kind == "proof-before-write" { p.f.files.beforeWrite = { path, _ in if path == cancelPath { throw HelperError.io("fixture write") } } }
            if kind == "proof-after-rename" { p.f.files.afterWrite = { path, _ in if path == cancelPath { throw HelperError.io("fixture after rename") } } }
            if kind == "proof-readback" { p.f.files.afterWrite = { path, _ in if path == cancelPath { p.f.files.beforeRead = { q in if q == cancelPath { throw HelperError.io("fixture readback") } } } } }
            if kind == "proof-unknown-readback" { p.f.files.afterWrite = { path, _ in if path == cancelPath { p.f.files.unknownPaths.insert(cancelPath) } } }
            if kind == "proof-mismatch-readback" { p.f.files.afterWrite = { path, _ in if path == cancelPath { p.f.files.data[cancelPath] = "corrupt" } } }
            if kind == "identity-after-proof" { p.f.files.afterWrite = { path, _ in if path == cancelPath { p.ids.values[123] = "reused-pid" } } }
            if kind == "consent-before-remove" { p.f.files.beforeRemove = { path in if path == stagePath { throw HelperError.io("fixture before remove") } } }
            if kind == "identity-before-remove" { p.f.files.beforeRemove = { path in if path == stagePath { p.ids.values[123] = "reused-pid"; throw HelperError.io("fixture identity") } } }
            if ["consent-after-remove", "consent-unknown-after-remove", "identity-after-remove", "proof-corrupt-after-remove"].contains(kind) {
                p.f.files.afterRemove = { path in if path == stagePath {
                    if kind == "consent-unknown-after-remove" { p.f.files.unknownPaths.insert(stagePath) }
                    if kind == "identity-after-remove" { p.ids.values[123] = "reused-pid" }
                    if kind == "proof-corrupt-after-remove" { p.f.files.data[cancelPath] = "corrupt" }
                    if kind == "consent-after-remove" { throw HelperError.io("fixture after remove") }
                } }
            }
            try p.denied(await p.send("protected-cancel-stage", input: p.input))
            let partial = p.f.files.data[cancelPath]
            if !["consent-after-remove", "consent-unknown-after-remove", "identity-after-remove", "proof-corrupt-after-remove"].contains(kind) {
                try check(p.f.files.data[stagePath] == consent, "no delete before write/readback/identity proof")
                try check(HelperStateStore(fileSystem: p.f.files, paths: paths).protectedPreStageConsentPending, "partial WAL keeps ordinary fence")
            }
            p.f.files.beforeWrite = nil; p.f.files.afterWrite = nil; p.f.files.beforeRead = nil
            p.f.files.beforeRemove = nil; p.f.files.afterRemove = nil; p.f.files.unknownPaths = []
            p.ids.values[123] = "fixture-start-1"; p.restart()
            if ["proof-mismatch-readback", "proof-corrupt-after-remove"].contains(kind) {
                try p.denied(await p.send("protected-cancel-stage", input: p.input))
                try check(p.f.files.data[cancelPath] == "corrupt", "corrupt proof never erased or inferred")
            } else {
                try check(await p.send("protected-cancel-stage", input: p.input) == cancelACK(p), "same exact retry completes")
                if let partial { try check(p.f.files.data[cancelPath] == partial, "retry never rewrites issued proof") }
                try check(p.f.files.data[stagePath] == nil, "private deletion proved")
            }
            try p.untouched()
        }
    }
    for kind in ["uid", "new-pid", "dead-owner", "pid-reuse", "signature", "unauthenticated", "forwarded-pid", "transaction",
                 "source", "candidate", "owner-token", "capability", "journal", "unknown-consent", "corrupt-proof", "unknown-proof"] {
        await test("retry-denied-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            _ = await p.send("protected-cancel-stage", input: p.input)
            let original = p.f.files.data[cancelPath]!
            var input = p.input
            switch kind {
            case "dead-owner": p.ids.values.removeValue(forKey: 123)
            case "pid-reuse": p.ids.values[123] = "reused-pid"
            case "signature": p.auth.allowed = false
            case "transaction": input = input.replacingOccurrences(of: p.transaction, with: UUID().uuidString)
            case "source": input = input.replacingOccurrences(of: digest(sourceConfig), with: String(repeating: "3", count: 64))
            case "candidate": input = input.replacingOccurrences(of: digest(candidateConfig), with: String(repeating: "4", count: 64))
            case "owner-token": input = input.replacingOccurrences(of: digest("fixture-intent"), with: String(repeating: "5", count: 64))
            case "capability": input = input.replacingOccurrences(of: capability, with: String(repeating: "ef", count: 32))
            case "journal": p.f.files.data[journalPath] = "pending journal must remain"
            case "unknown-consent": p.f.files.unknownPaths.insert(stagePath)
            case "corrupt-proof": p.f.files.data[cancelPath] = "corrupt"
            case "unknown-proof": p.f.files.unknownPaths.insert(cancelPath)
            default: break
            }
            let owner = p.f.files.data[paths.ownerSessionPath]
            let reply = await p.send("protected-cancel-stage", input: input, pid: kind == "new-pid" ? 124 : 123,
                uid: kind == "uid" ? 502 : 501, authenticated: kind != "unauthenticated", forwardedPID: kind == "forwarded-pid" ? 124 : nil)
            try p.denied(reply)
            try check(p.f.files.data[cancelPath] == (kind == "corrupt-proof" ? "corrupt" : original)
                && p.f.files.data[paths.ownerSessionPath] == owner, "no overwrite or ownership write")
            if kind == "journal" { try check(p.f.files.data[journalPath] == "pending journal must remain", "no consumed journal deletion") }
        }
    }
    await test("absence-without-root-proof-never-infers-cancellation") {
        let p = try PreFixture(); try await p.authorize(); p.f.files.data.removeValue(forKey: stagePath)
        Clock.shared.seconds += 121; p.restart()
        try p.denied(await p.send("protected-cancel-stage", input: p.input))
        try check(p.f.files.data[cancelPath] == nil, "absence/expiry not proof")
        try p.untouched()
    }
    await test("cancelled-nonce-capability-cannot-stage-replace-or-renew-after-snapshot") {
        let p = try PreFixture(); try await p.authorize()
        let oldInput = p.input, oldMetadata = p.metadata
        _ = await p.send("protected-cancel-stage", input: oldInput)
        try p.denied(await p.send("protected-replace", input: oldMetadata))
        let saved = p.f.files.data[cancelPath]!
        try await p.grant()
        try p.denied(await p.send("protected-authorize-stage", input: p.input)) // same cap, different nonce
        let owner = OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!
        let stage = ProtectedPreStageConsentStore(files: p.f.files, paths: paths, clock: Clock.shared)
        let request = try ProtectedOwnerTransferRequest(metadata: oldInput.split(separator: " ").map(String.init))
        try check(rejected { _ = try stage.authorize(request, uid: 501, candidate: { candidateConfig }, validateOwner: { owner }, validateSource: {}) }, "cancelled exact tuple cannot renew directly")
        try check(p.f.files.data[cancelPath] == saved && p.f.files.data[stagePath] == nil, "no TTL/write revival")
        try p.untouched()
    }
    await test("new-explicit-nonce-capability-only-supersedes-on-next-proved-cancel") {
        let p = try PreFixture(); try await p.authorize(); let oldInput = p.input
        _ = await p.send("protected-cancel-stage", input: oldInput); let saved = p.f.files.data[cancelPath]!
        try await p.grant(); let fresh = p.input.replacingOccurrences(of: capability, with: String(repeating: "ef", count: 32))
        try check((await p.send("protected-authorize-stage", input: fresh)).hasPrefix("stage-authorized "), "fresh one-use nonce and cap")
        try check(p.f.files.data[cancelPath] == saved, "authorizing/snapshot never discards proof")
        try p.denied(await p.send("protected-cancel-stage", input: oldInput)) // cannot delete new consent
        try check(await p.send("protected-cancel-stage", input: fresh) == cancelACK(p), "different exact proved cancellation supersedes bounded receipt")
        try check(try proof(p).consent.transactionID == p.transaction && p.f.files.data[stagePath] == nil, "latest receipt pinned, no unbounded files")
        try p.untouched()
    }
    for kind in ["journal", "receipt"] {
        await test("consumed-authority-preserved-" + kind) {
            let p = try PreFixture(); try await p.authorize(); try await p.replace()
            if kind == "receipt" { _ = await p.send("protected-commit", input: p.metadata) }
            let saved = p.f.files.data[kind == "journal" ? journalPath : receiptPath]!, ports = physical(p)
            let reply = await p.send("protected-cancel-stage", input: p.input)
            if kind == "journal" {
                try check(reply.hasPrefix("error:") && p.f.files.data[cancelPath] == nil && p.f.files.data[stagePath] != nil, "pending journal forbids cancellation")
            } else {
                try check(reply == cancelACK(p) && proof(p).evidenceKind == "receipt", "compatible consumed metadata cleanup, not nonce proof")
                let owner = p.f.files.data[paths.ownerSessionPath]
                try check((await p.send("protected-authorize-restart", input: p.input)).hasPrefix("error:"), "cancelled capability cannot renew from retained receipt")
                p.ids.values.removeValue(forKey: 123); p.restart()
                try check((await p.send("protected-adopt-restart", input: p.input, pid: 124)).hasPrefix("error:")
                    && p.f.files.data[paths.ownerSessionPath] == owner && p.f.files.data[transferPath] == nil, "no post-cancel adoption/owner write")
            }
            try check(p.f.files.data[kind == "journal" ? journalPath : receiptPath] == saved && physical(p) == ports,
                "journal/receipt bytes and physical ports unchanged")
        }
    }
    await test("exact-source-recovery-cancel-proof-is-not-a-second-recovery") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        try check((await p.send("protected-recover", input: p.metadata)).hasPrefix("recovered "), "real root source recovery")
        let ports = physical(p)
        try check(await p.send("protected-cancel-stage", input: p.input) == cancelACK(p) && proof(p).evidenceKind == "source", "changed utun source is proved before metadata cleanup")
        try check(await p.send("protected-cancel-stage", input: p.input) == cancelACK(p) && physical(p) == ports,
            "repeated ACK no physical recovery")
    }
    for verb in ["up", "down", "shutdown", "repair", "attach-owner", "antileak-off", "protected-snapshot", "protected-authorize-stage", "protected-authorize-restart", "protected-adopt-restart"] {
        await test("corrupt-proof-fences-" + verb) {
            let p = try PreFixture(); try await p.authorize(); _ = await p.send("protected-cancel-stage", input: p.input)
            p.f.files.data[cancelPath] = "corrupt"; p.restart()
            let input: String? = verb.hasPrefix("protected-") && verb != "protected-snapshot" ? p.input : (verb == "attach-owner" ? "owner_pid=124" : nil)
            try p.denied(await p.send(verb, input: input))
            try check(HelperStateStore(fileSystem: p.f.files, paths: paths).protectedPreStageConsentPending, "unknown proof never opens ordinary fence")
        }
    }
    for kind in ["good", "mode", "symlink", "hardlink", "oversize", "unknown-field", "duplicate-field", "noncanonical", "digest", "kind", "clock", "nested-consent"] {
        await test("actual-private-cancel-proof-" + kind) {
            let p = try PreFixture(); try await p.authorize(); _ = await p.send("protected-cancel-stage", input: p.input)
            let root = CommandLine.arguments[1] + "/cancel-proof-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: root) }
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let files = LocalFileSystem(), layout = isolatedPaths(root)
            let store = ProtectedPreStageConsentStore(files: files, paths: layout, clock: Clock.shared)
            var text = p.f.files.data[cancelPath]!
            if kind == "oversize" { text = String(repeating: "x", count: 16_385) }
            if kind == "unknown-field" { text = text.replacingOccurrences(of: "{", with: "{\"extra\":true,") }
            if kind == "duplicate-field" { text = text.replacingOccurrences(of: "{", with: "{\"schemaVersion\":1,") }
            if kind == "noncanonical" { text = " " + text }
            if ["digest", "kind", "clock", "nested-consent"].contains(kind) {
                var obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                if kind == "digest" { obj["consentSHA256"] = String(repeating: "0", count: 64) }
                if kind == "kind" { obj["evidenceKind"] = "admission" }
                if kind == "clock" { obj["cancelledAt"] = 0 }
                if kind == "nested-consent" { var c = obj["consent"] as! [String: Any]; c["expiresAt"] = 1; obj["consent"] = c }
                text = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self) + "\n"
            }
            try files.writeTextAtomically(text, to: store.cancellationPath, mode: kind == "mode" ? 0o644 : 0o600)
            if kind == "symlink" { try FileManager.default.moveItem(atPath: store.cancellationPath, toPath: root + "/linked"); try FileManager.default.createSymbolicLink(atPath: store.cancellationPath, withDestinationPath: root + "/linked") }
            if kind == "hardlink" { try FileManager.default.linkItem(atPath: store.cancellationPath, toPath: root + "/linked") }
            try check(((try? store.cancellationIfPresent()) != nil) == (kind == "good"), "strict private proof custody")
            try check(HelperStateStore(fileSystem: files, paths: layout).protectedPreStageConsentPending == (kind != "good"), "unsafe proof not absence")
            try p.untouched()
        }
    }
    print("pre_stage_cancel_receipt_matrix cases=\(cases) failures=\(failures) live_network_commands=0 OS_crash_acceptance=not_claimed")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''

if __name__ == "__main__":
    scratch = Path(os.environ.get("TMPDIR", "/private/tmp")).resolve()
    with tempfile.TemporaryDirectory(prefix="pre-stage-cancel-", dir=scratch) as raw:
        d = Path(raw)
        (d / "main.swift").write_text(prefix + HARNESS)
        built = subprocess.run(["rtk", "proxy", "swiftc", "-swift-version", "5", *map(str, sorted(CORE.glob("*.swift"))),
                                str(d / "main.swift"), "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm", "-o", str(d / "probe")],
                               capture_output=True, timeout=180)
        sys.stdout.buffer.write(built.stdout); sys.stderr.buffer.write(built.stderr)
        if built.returncode: raise SystemExit(built.returncode)
        result = subprocess.run(["rtk", "proxy", str(d / "probe"), str(d)], capture_output=True, timeout=180)
        sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)
        names = [line.split(" ")[1].split("=")[0] for line in result.stdout.decode().splitlines() if line.startswith("pre_stage_cancel_receipt ")]
        if len(names) != 58 or len(set(names)) != 58 or b"pre_stage_cancel_receipt_matrix cases=58 " not in result.stdout: raise SystemExit(1)
        raise SystemExit(result.returncode)

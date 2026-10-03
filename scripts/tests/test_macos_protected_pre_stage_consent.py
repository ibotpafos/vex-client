#!/usr/bin/env python3
"""Actual root pre-stage RPC/store/journal; only inert physical ports execute.

One frozen evaluator accepts the same source root for B/M/R. Missing contract
is reported as absence, not as an executed failing runtime branch. No app,
installed helper, real route/DNS/PF, API, keychain or signing identity runs.
"""
import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
if not (CORE / "ProtectedPreStageConsent.swift").is_file():
    print("protected_pre_stage contract=ABSENT runtime_not_executed=true")
    print("protected_pre_stage_matrix cases=1 failures=1 live_network_commands=0")
    sys.exit(1)


def literal(path, name):
    tree = ast.parse(path.read_text())
    return next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))


prefix = literal(ROOT / "scripts/tests/test_macos_protected_replacement.py", "HARNESS").split("// Child processes only", 1)[0]
prefix = prefix.replace('var currentIF = "utun7", up = 0, down = 0',
                        'var currentIF = "utun7", up = 0, down = 0\n    var handshake: UInt64 = 1_800_000_000')
prefix = prefix.replace(r'\t1\t12\t13\t25', r'\t\(handshake)\t12\t13\t25')
prefix = prefix.replace('var data: [String: String] = [:]',
                        'var data: [String: String] = [:]; var modes: [String: Int] = [:]; var unknownPaths = Set<String>()')
prefix = prefix.replace('func fileExists(at path: String)',
                        'func pathPresence(at path: String) -> HelperPathPresence { unknownPaths.contains(path) ? .unknown : (data[path] == nil ? .absent : .present) }\n    func fileExists(at path: String)')
prefix = prefix.replace('try beforeWrite?(path, text); data[path] = text;',
                        'try beforeWrite?(path, text); modes[path] = mode; data[path] = text;')
prefix = prefix.replace('var active = true, updates = 0, enables = 0, disables = 0',
                        'var active = true, updates = 0, enables = 0, disables = 0\n    var beforeUpdate: (() throws -> Void)?')
prefix = prefix.replace('        updates += 1', '        try beforeUpdate?()\n        updates += 1')
prefix = prefix.replace('runner: runner, firewall: pf)', 'runner: runner, firewall: pf, dateProvider: Clock.shared)')
prefix += literal(ROOT / "scripts/tests/test_macos_protected_owner_transfer.py", "HARNESS").split("let transferPath", 1)[0]

HARNESS = r'''
let stagePath = paths.helperDirectory + "/protected-pre-stage-consent.state"
let transferPath = paths.helperDirectory + "/protected-owner-transfer.state"
let receiptPath = paths.helperDirectory + "/replacement-commit-receipt.state"
let capability = String(repeating: "cd", count: 32) // test-only, not a real credential
final class PreFixture {
    let f = Fixture(), ids = Identities(), auth = Auth(), log = Log()
    var runtime: HelperRuntime!
    var transaction = "E63DCEBD-109A-4C45-A23C-3F32BF42597A"
    init() throws {
        Clock.shared.seconds = 1_800_000_000
        try HelperStateStore(fileSystem: f.files, paths: paths).persistSession(f.source)
        restart()
    }
    var metadata: String {
        "transaction_id=\(transaction) source_sha256=\(digest(sourceConfig)) candidate_sha256=\(digest(candidateConfig)) owner_token_sha256=\(digest("fixture-intent"))"
    }
    var input: String { metadata + " restart_capability=" + capability }
    func restart() {
        runtime = HelperRuntime(store: HelperStateStore(fileSystem: f.files, paths: paths, dateProvider: Clock.shared),
            tunnelController: f.controller, firewallController: f.pf, processInspector: ids,
            dateProvider: Clock.shared, logger: log, protectedPeerAuthenticator: auth)
    }
    func send(_ verb: String, input: String? = nil, pid: Int32 = 123, uid: UInt32 = 501,
              authenticated: Bool = true, forwardedPID: Int32? = nil) async -> String {
        await runtime.handle(commandLine: verb + (input.map { " " + $0 } ?? ""), peerPID: forwardedPID ?? pid,
            authenticatedPeer: authenticated ? PeerCredentials(pid: pid, auditToken: Data([7]), effectiveUID: uid) : nil).payload
    }
    func grant() async throws {
        let reply = await send("protected-snapshot")
        guard let field = reply.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("transaction_id=") }) else { throw HelperError.io("fixture grant absent") }
        transaction = String(field.dropFirst("transaction_id=".count))
        try check(UUID(uuidString: transaction)?.uuidString == transaction, "actual root nonce")
    }
    func authorize() async throws {
        try await grant()
        let reply = await send("protected-authorize-stage", input: input)
        try check(reply == "stage-authorized transaction_id=\(transaction) expires_at=1800000120\n", "exact stage acknowledgement")
        try untouched()
    }
    func untouched() throws {
        try check(f.runner.up == 0 && f.runner.down == 0 && f.pf.updates == 0 && f.pf.enables == 0 && f.pf.disables == 0 && f.pf.active,
            "no physical port before admission")
        try check(f.files.data[paths.activeConfigPath] == sourceConfig && f.files.data[paths.dnsStatePath] == dnsBaseline,
            "source and DNS unchanged")
    }
    func denied(_ reply: String) throws {
        try check(reply.hasPrefix("error:") && !reply.contains(capability), "denied and redacted")
        try check(f.runner.up == 0 && f.runner.down == 0 && f.pf.updates == 0 && f.pf.enables == 0 && f.pf.disables == 0 && f.pf.active,
            "denied before physical mutation, externally injected fixture bytes retained")
    }
    func replace() async throws {
        var observed = 0
        f.pf.beforeUpdate = {
            let journal = try ProtectedReplacementJournal.decode(self.f.files.data[journalPath]!)
            try check(journal.preStageConsentSHA256 == digest(self.f.files.data[stagePath]!), "consent attached before every PF port")
            if observed == 0 { try check(journal.phase == "prepared", "first physical port follows prepared journal") }
            observed += 1
        }
        let reply = await send("protected-replace", input: metadata)
        try check(reply == "ready transaction_id=\(transaction) candidate_sha256=\(digest(candidateConfig))\n", "exact ready acknowledgement")
        try check(observed >= 1 && f.runner.down == 1 && f.runner.up == 1 && f.pf.active && f.pf.disables == 0,
            "exact physical fake-port transition, no PF disable")
        let j = try ProtectedReplacementJournal.decode(f.files.data[journalPath]!)
        try check(j.phase == "awaiting-handshake" && j.preStageConsentSHA256 == digest(f.files.data[stagePath]!), "durable attachment retained")
    }
}
Task {
    var cases = 0, failures = 0
    func test(_ name: String, _ body: () async throws -> Void) async {
        cases += 1
        do { try await body(); print("protected_pre_stage \(name)=PASS") }
        catch { failures += 1; print("protected_pre_stage \(name)=FAIL \(error.localizedDescription)") }
    }
    await test("original-live-consent-private-bounded-redacted-idempotent") {
        let p = try PreFixture(); try await p.authorize()
        let saved = p.f.files.data[stagePath]!
        let r = try ProtectedPreStageConsent.decode(saved)
        try check(r.uid == 501 && r.issuedAt == 1_800_000_000 && r.expiresAt == 1_800_000_120,
            "original kernel UID and bounded immutable expiry")
        try check(p.f.files.modes[stagePath] == 0o600 && !saved.contains(capability) && !saved.contains("PrivateKey"), "root private hashes only")
        let retry = await p.send("protected-authorize-stage", input: p.input)
        try check(retry.hasPrefix("stage-authorized ") && p.f.files.data[stagePath] == saved, "same owner exact retry never extends TTL")
        try p.untouched()
    }
    await test("consent-attached-before-first-physical-port-not-a-transfer-fence") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        try check(p.f.files.data[transferPath] == nil, "not owner-transfer authorization during replacement")
    }
    await test("journal-attachment-bridges-restart-without-old-owner-authorize-RPC") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        let physical = (p.f.runner.up, p.f.runner.down, p.f.pf.updates)
        p.ids.values.removeValue(forKey: 123); p.restart()
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(reply.hasPrefix("owner-transferred ") && reply.contains("evidence_kind=journal"), "original consent plus exact journal, not dead PID")
        let owner = OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!
        let j = try ProtectedReplacementJournal.decode(p.f.files.data[journalPath]!)
        try check(owner.pid == 124 && j.ownerPID == 124 && j.preStageConsentSHA256 == digest(p.f.files.data[stagePath]!), "binding survives narrow owner rewrite")
        try check(physical.0 == p.f.runner.up && physical.1 == p.f.runner.down && physical.2 == p.f.pf.updates, "no physical operation on ownership transfer")
        let next = "transaction_id=\(p.transaction) source_sha256=\(digest(sourceConfig)) candidate_sha256=\(digest(candidateConfig)) owner_token_sha256=\(digest(owner.token))"
        let receipt = await p.send("protected-receipt", input: next, pid: 124)
        try check(receipt.hasPrefix("error:"), "journal transfer is not a receipt or admission")
    }
    await test("fresh-root-commit-preserves-receipt-attachment-for-explicit-restart") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        let committed = await p.send("protected-commit", input: p.metadata)
        try check(committed.hasPrefix("committed "), "fresh real root commit")
        let r = try ProtectedReplacementCommitReceipt.decode(p.f.files.data[receiptPath]!)
        try check(r.preStageConsentSHA256 == digest(p.f.files.data[stagePath]!) && p.f.files.data[journalPath] == nil, "receipt attachment precedes journal removal")
        p.ids.values.removeValue(forKey: 123); p.restart()
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(reply.hasPrefix("owner-transferred ") && reply.contains("evidence_kind=receipt"), "attached receipt can enter old exact explicit recovery")
        let rebound = try ProtectedReplacementCommitReceipt.decode(p.f.files.data[receiptPath]!)
        try check(rebound.ownerPID == 124 && rebound.preStageConsentSHA256 == r.preStageConsentSHA256, "receipt normalization preserves attachment")
    }
    for kind in ["expired", "wrong-capability", "uid", "signature", "new-pid", "old-pid-reuse", "source", "dns", "missing-binding", "foreign-binding", "changed-source-session", "record-corrupt", "receipt-binding"] {
        await test("attached-restart-reject-" + kind) {
            let p = try PreFixture(); try await p.authorize(); try await p.replace()
            if kind == "receipt-binding" {
                _ = await p.send("protected-commit", input: p.metadata)
                var r = try ProtectedReplacementCommitReceipt.decode(p.f.files.data[receiptPath]!)
                r.preStageConsentSHA256 = nil; p.f.files.data[receiptPath] = try r.encoded()
            } else if kind == "missing-binding" || kind == "foreign-binding" || kind == "changed-source-session" {
                var j = try ProtectedReplacementJournal.decode(p.f.files.data[journalPath]!)
                if kind == "missing-binding" { j.preStageConsentSHA256 = nil }
                if kind == "foreign-binding" { j.preStageConsentSHA256 = String(repeating: "9", count: 64) }
                if kind == "changed-source-session" {
                    let obj = try JSONSerialization.jsonObject(with: Data(try j.encoded().utf8)) as! [String: Any]
                    var altered = obj; altered["sourceSession"] = j.sourceSession.replacingOccurrences(of: "latest_handshake=1", with: "latest_handshake=2")
                    let e = try JSONSerialization.data(withJSONObject: altered, options: [.sortedKeys])
                    j = try ProtectedReplacementJournal.decode(String(decoding: e, as: UTF8.self) + "\n")
                }
                p.f.files.data[journalPath] = try j.encoded()
            }
            let physical = (p.f.runner.up, p.f.runner.down, p.f.pf.updates)
            let originalOwner = p.f.files.data[paths.ownerSessionPath]
            p.ids.values.removeValue(forKey: 123); p.restart()
            switch kind {
            case "expired": Clock.shared.seconds += 121
            case "signature": p.auth.allowed = false
            case "new-pid": p.ids.values[124] = nil
            case "old-pid-reuse": p.ids.values[123] = "reused-old-pid"
            case "source": p.f.files.data[paths.activeConfigPath] = config("198.51.100.9:51820")
            case "dns": p.f.files.data[paths.dnsStatePath] = "changed"
            case "record-corrupt": p.f.files.data[stagePath] = "corrupt"
            default: break
            }
            let input = kind == "wrong-capability" ? p.input.replacingOccurrences(of: capability, with: String(repeating: "ef", count: 32)) : p.input
            let reply = await p.send("protected-adopt-restart", input: input, pid: 124, uid: kind == "uid" ? 502 : 501)
            try check(reply.hasPrefix("error:") && !reply.contains(capability), "invalid exact attached restart denied")
            try check(p.f.files.data[transferPath] == nil && p.f.files.data[paths.ownerSessionPath] == originalOwner,
                "no ownership write on invalid consent/attachment/peer")
            try check(physical.0 == p.f.runner.up && physical.1 == p.f.runner.down && physical.2 == p.f.pf.updates,
                "restart denial has no physical effects")
        }
    }
    for kind in ["legacy-bypass", "expired-consent"] {
        await test("direct-root-reject-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            let owner = OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!
            let request = try ProtectedReplacementRequest(metadata: p.metadata.split(separator: " ").map(String.init))
            var rejected = false
            do {
                if kind == "legacy-bypass" { _ = try p.f.controller.replaceProtected(request: request, validateOwner: { owner }) }
                else {
                    Clock.shared.seconds += 121
                    _ = try p.f.controller.replaceWithPreStageConsent(request: request, uid: 501,
                        consentCapabilitySHA256: digest(capability), validateOwner: { owner })
                }
            } catch { rejected = true }
            try check(rejected && p.f.files.data[journalPath] == nil, "no legacy fallback or expiry admission")
            try p.untouched()
        }
    }
    await test("consumed-grant-cannot-repeat-replacement") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        let physical = (p.f.runner.up, p.f.runner.down, p.f.pf.updates)
        let reply = await p.send("protected-replace", input: p.metadata)
        try check(reply.hasPrefix("error:") && physical.0 == p.f.runner.up && physical.1 == p.f.runner.down && physical.2 == p.f.pf.updates,
            "durable journal and one-use grant block replay")
    }
    await test("same-live-owner-can-cancel-consent-after-exact-source-recovery") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        let recovered = await p.send("protected-recover", input: p.metadata)
        try check(recovered.hasPrefix("recovered ") && p.f.files.data[paths.activeConfigPath] == sourceConfig,
            "actual root source restoration proof")
        let physical = (p.f.runner.up, p.f.runner.down, p.f.pf.updates)
        let reply = await p.send("protected-cancel-stage", input: p.input)
        try check(reply.hasPrefix("stage-cancelled ") && p.f.files.data[stagePath] == nil,
            "live original owner exact cleanup after changed utun and handshake")
        try check(physical.0 == p.f.runner.up && physical.1 == p.f.runner.down && physical.2 == p.f.pf.updates,
            "private cancellation never repeats source recovery")
    }
    for verb in ["up", "down", "shutdown", "repair", "attach-owner", "antileak-off"] {
        await test("unattached-consent-fences-ordinary-" + verb) {
            let p = try PreFixture(); try await p.authorize()
            Clock.shared.seconds += 121; p.ids.values.removeValue(forKey: 123)
            let reply = await p.send(verb, input: verb == "attach-owner" ? "owner_pid=124" : nil, pid: 124)
            try p.denied(reply)
            let store = HelperStateStore(fileSystem: p.f.files, paths: paths)
            try check(store.protectedOperationRecoveryPending && store.protectedPreStageConsentPending, "expiry/death never opens ordinary cleanup")
        }
    }
    await test("orphaned-consent-cannot-transfer-after-death-or-helper-restart") {
        let p = try PreFixture(); try await p.authorize(); p.ids.values.removeValue(forKey: 123); p.restart()
        try p.denied(await p.send("protected-adopt-restart", input: p.input, pid: 124))
        try check(p.f.files.data[transferPath] == nil && OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!.pid == 123,
            "no root journal or receipt, no ownership write")
        try p.denied(await p.send("protected-replace", input: p.metadata, pid: 124))
    }
    for kind in ["no-grant", "nonce", "source", "candidate", "owner", "capability", "duplicate", "unknown", "bad-stage", "wrong-peer", "unauthenticated", "signature", "dead-owner", "pid-reuse", "clock-backwards", "grant-expired"] {
        await test("authorize-reject-" + kind) {
            let p = try PreFixture(); if kind != "no-grant" { try await p.grant() }
            var input = p.input; var pid: Int32 = 123
            switch kind {
            case "nonce": input = input.replacingOccurrences(of: p.transaction, with: "F63DCEBD-109A-4C45-A23C-3F32BF42597A")
            case "source": input = input.replacingOccurrences(of: digest(sourceConfig), with: String(repeating: "3", count: 64))
            case "candidate": input = input.replacingOccurrences(of: digest(candidateConfig), with: String(repeating: "4", count: 64))
            case "owner": input = input.replacingOccurrences(of: digest("fixture-intent"), with: String(repeating: "5", count: 64))
            case "capability": input = input.replacingOccurrences(of: capability, with: "short")
            case "duplicate": input += " restart_capability=" + capability
            case "unknown": input += " extra=true"
            case "bad-stage": p.f.files.data[paths.defaultConfigPath] = "bad config"
            case "wrong-peer": pid = 124
            case "signature": p.auth.allowed = false
            case "dead-owner": p.ids.values.removeValue(forKey: 123)
            case "pid-reuse": p.ids.values[123] = "fixture-reused-start"
            case "clock-backwards": Clock.shared.seconds -= 1
            case "grant-expired": Clock.shared.seconds += 31
            default: break
            }
            try p.denied(await p.send("protected-authorize-stage", input: input, pid: pid, authenticated: kind != "unauthenticated"))
            try check(p.f.files.data[stagePath] == nil && p.f.files.data[journalPath] == nil, "no consent/journal on invalid request")
        }
    }
    for kind in ["absent", "corrupt", "unknown-presence", "owner-death", "pid-reuse", "signature", "uid", "candidate", "source", "DNS", "session", "owner-token", "capability-substitution", "grant-expired", "clock-backwards"] {
        await test("consume-reject-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            switch kind {
            case "absent": p.f.files.data.removeValue(forKey: stagePath)
            case "corrupt": p.f.files.data[stagePath] = "bad state"
            case "unknown-presence": p.f.files.unknownPaths.insert(stagePath)
            case "owner-death": p.ids.values.removeValue(forKey: 123)
            case "pid-reuse": p.ids.values[123] = "fixture-reused-start"
            case "signature": p.auth.allowed = false
            case "candidate": p.f.files.data[paths.defaultConfigPath] = config("198.51.100.9:51820")
            case "source": p.f.files.data[paths.activeConfigPath] = config("198.51.100.9:51820")
            case "DNS": p.f.files.data[paths.dnsStatePath] = "changed DNS"
            case "session": p.f.files.data[paths.sessionStatePath] = p.f.source.payload + "extra=true\n"
            case "owner-token": p.f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "other", identity: "fixture-start-1").payload
            case "capability-substitution":
                p.f.files.data[stagePath] = p.f.files.data[stagePath]!.replacingOccurrences(of: digest(capability), with: digest(String(repeating: "ef", count: 32)))
            case "grant-expired": Clock.shared.seconds += 31
            case "clock-backwards": Clock.shared.seconds -= 1
            default: break
            }
            try p.denied(await p.send("protected-replace", input: p.metadata, uid: kind == "uid" ? 502 : 501))
            try check(p.f.files.data[journalPath] == nil, "rejected before prepared journal")
        }
    }
    for kind in ["record-write", "record-after-rename", "record-readback", "identity-after-record", "journal-write", "journal-after-rename", "record-after-journal", "stage-after-journal", "identity-after-journal"] {
        await test("IO-boundary-" + kind) {
            let p = try PreFixture(); try await p.grant()
            if kind == "record-write" { p.f.files.beforeWrite = { path, _ in if path == stagePath { throw HelperError.io("fixture write") } } }
            if kind == "record-after-rename" { p.f.files.afterWrite = { path, _ in if path == stagePath { throw HelperError.io("fixture rename") } } }
            if kind == "record-readback" { p.f.files.afterWrite = { path, _ in if path == stagePath { p.f.files.beforeRead = { q in if q == stagePath { throw HelperError.io("fixture readback") } } } } }
            if kind == "identity-after-record" { p.f.files.afterWrite = { path, _ in if path == stagePath { p.ids.values[123] = "fixture-reused-start" } } }
            let auth = await p.send("protected-authorize-stage", input: p.input)
            if ["record-write", "record-after-rename", "record-readback", "identity-after-record"].contains(kind) { try p.denied(auth); return }
            try check(auth.hasPrefix("stage-authorized "), "consent persisted before journal fault")
            if kind == "journal-write" { p.f.files.beforeWrite = { path, _ in if path == journalPath { throw HelperError.io("fixture journal") } } }
            if kind == "journal-after-rename" { p.f.files.afterWrite = { path, _ in if path == journalPath { throw HelperError.io("fixture journal rename") } } }
            if kind == "record-after-journal" { p.f.files.afterWrite = { path, _ in if path == journalPath { p.f.files.data[stagePath] = "corrupt" } } }
            if kind == "stage-after-journal" { p.f.files.afterWrite = { path, _ in if path == journalPath { p.f.files.data[paths.defaultConfigPath] = config("198.51.100.9:51820") } } }
            if kind == "identity-after-journal" { p.f.files.afterWrite = { path, _ in if path == journalPath { p.ids.values[123] = "fixture-reused-start" } } }
            try p.denied(await p.send("protected-replace", input: p.metadata))
        }
    }
    await test("prepared-journal-after-rename-error-can-transfer-no-physical-work") {
        let p = try PreFixture(); try await p.authorize()
        p.f.files.afterWrite = { path, _ in if path == journalPath { throw HelperError.io("fixture sync failure") } }
        try p.denied(await p.send("protected-replace", input: p.metadata)); p.f.files.afterWrite = nil
        p.ids.values.removeValue(forKey: 123); p.restart()
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(reply.hasPrefix("owner-transferred ") && reply.contains("evidence_kind=journal"), "exact prepared attachment, never orphan consent")
        try p.untouched()
    }
    await test("fresh-handshake-still-required-consent-and-ready-never-commit") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        p.f.runner.handshake = 1
        let reply = await p.send("protected-commit", input: p.metadata)
        try check(reply == "error: protected replacement awaiting fresh handshake\n" && p.f.files.data[receiptPath] == nil && p.f.files.data[journalPath] != nil,
            "old source handshake never confirms candidate")
    }
    await test("same-original-live-owner-cancels-expired-orphan-with-no-physical-work") {
        let p = try PreFixture(); try await p.authorize(); Clock.shared.seconds += 121
        let reply = await p.send("protected-cancel-stage", input: p.input)
        try check(reply == "stage-cancelled transaction_id=\(p.transaction)\n" && p.f.files.data[stagePath] == nil, "exact explicit expired cancellation")
        try p.untouched()
    }
    for kind in ["wrong-peer", "wrong-capability", "wrong-uid", "journal", "unknown-presence"] {
        await test("cancel-reject-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            if kind == "journal" { p.f.files.data[journalPath] = "unreadable pending journal" }
            if kind == "unknown-presence" { p.f.files.unknownPaths.insert(stagePath) }
            let input = kind == "wrong-capability" ? p.input.replacingOccurrences(of: capability, with: String(repeating: "ef", count: 32)) : p.input
            try p.denied(await p.send("protected-cancel-stage", input: input, pid: kind == "wrong-peer" ? 124 : 123, uid: kind == "wrong-uid" ? 502 : 501))
            try check(p.f.files.data[stagePath] != nil, "cannot discard pending authority")
        }
    }
    for kind in ["good", "mode", "symlink", "hardlink", "oversize", "unknown-field", "duplicate-field"] {
        await test("actual-private-consent-file-" + kind) {
            let p = try PreFixture(); try await p.authorize()
            let parent = CommandLine.arguments[1]
            let root = parent + "/pre-stage-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: root) }
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let files = LocalFileSystem(), layout = isolatedPaths(root)
            let store = ProtectedPreStageConsentStore(files: files, paths: layout, clock: Clock.shared)
            var text = p.f.files.data[stagePath]!
            if kind == "oversize" { text = String(repeating: "x", count: 16_385) }
            if kind == "unknown-field" { text = text.replacingOccurrences(of: "{", with: "{\"extra\":true,") }
            if kind == "duplicate-field" { text = text.replacingOccurrences(of: "{", with: "{\"schemaVersion\":1,") }
            try files.writeTextAtomically(text, to: store.recordPath, mode: kind == "mode" ? 0o644 : 0o600)
            if kind == "symlink" {
                try FileManager.default.moveItem(atPath: store.recordPath, toPath: root + "/linked")
                try FileManager.default.createSymbolicLink(atPath: store.recordPath, withDestinationPath: root + "/linked")
            }
            if kind == "hardlink" { try FileManager.default.linkItem(atPath: store.recordPath, toPath: root + "/linked") }
            let saved = try? store.read()
            try check((saved != nil) == (kind == "good"), "descriptor based strict private custody")
            try p.untouched()
        }
    }
    await test("legacy-journal-and-receipt-encoding-without-consent-remain-compatible") {
        let p = try PreFixture(); try await p.grant()
        let ready = await p.send("protected-replace", input: p.metadata)
        try check(ready.hasPrefix("ready "), "old authenticated replacement stays supported")
        try check(!p.f.files.data[journalPath]!.contains("preStageConsentSHA256"), "legacy journal field remains absent")
        let committed = await p.send("protected-commit", input: p.metadata)
        try check(committed.hasPrefix("committed ") && !p.f.files.data[receiptPath]!.contains("preStageConsentSHA256"), "legacy receipt field remains absent")
    }
    await test("completed-consent-does-not-break-a-new-legacy-authenticated-tuple") {
        let p = try PreFixture(); try await p.authorize(); try await p.replace()
        _ = await p.send("protected-commit", input: p.metadata)
        let snapshot = await p.send("protected-snapshot")
        let field = snapshot.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("transaction_id=") })!
        let tx = String(field.dropFirst("transaction_id=".count))
        let next = config("198.51.100.9:51820"); p.f.files.data[paths.defaultConfigPath] = next
        let metadata = "transaction_id=\(tx) source_sha256=\(digest(candidateConfig)) candidate_sha256=\(digest(next)) owner_token_sha256=\(digest("fixture-intent"))"
        p.f.pf.beforeUpdate = nil
        let ready = await p.send("protected-replace", input: metadata)
        try check(ready.hasPrefix("ready ") && !p.f.files.data[journalPath]!.contains("preStageConsentSHA256"),
            "fresh legacy transaction does not reuse prior consumed authority")
    }
    await test("capability-errors-always-redacted-in-misrouted-command-and-logs") {
        let p = try PreFixture()
        let reply = await p.send("up", input: "restart_capability=" + capability)
        try check(reply.hasPrefix("error:") && !reply.contains(capability) && !p.log.messages.joined().contains(capability), "redaction for unknown protocol metadata")
        try p.untouched()
    }
    print("protected_pre_stage_matrix cases=\(cases) failures=\(failures) live_network_commands=0 OS_crash_acceptance=not_claimed client_integration=not_claimed")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''

scratch = Path(os.environ.get("TMPDIR", str(ROOT.parent / ".vex-tmp"))).resolve()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="protected-pre-stage-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(prefix + HARNESS)
    command = ["rtk", "proxy", "swiftc", "-swift-version", "5",
               *map(str, sorted(CORE.glob("*.swift"))), str(directory / "main.swift"),
               "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm", "-o", str(directory / "probe")]
    built = subprocess.run(command, timeout=180)
    if built.returncode:
        sys.exit(built.returncode)
    sys.exit(subprocess.run(["rtk", "proxy", str(directory / "probe"), str(directory)], timeout=180).returncode)

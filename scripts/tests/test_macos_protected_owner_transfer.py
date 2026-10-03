#!/usr/bin/env python3
"""Actual helper restart-ownership RPCs; every network port is an inert dictionary.

One immutable evaluator accepts a source root for BASELINE/MODIFIED/ROLLBACK.
No installed helper, ordinary app, live route/DNS/PF or production identity runs.
The reused fixture is literal data, not an executed historical test runner.
"""
import ast
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
fixture = ROOT / "scripts/tests/test_macos_protected_replacement.py"
tree = ast.parse(fixture.read_text())
foundation = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == "HARNESS" for t in n.targets))
prefix = foundation.split("// Child processes only", 1)[0]
prefix = prefix.replace('var currentIF = "utun7", up = 0, down = 0',
                        'var currentIF = "utun7", up = 0, down = 0, calls = 0\n    var handshake: UInt64 = 1000')
prefix = prefix.replace(r'\t1\t12\t13\t25', r'\t\(handshake)\t12\t13\t25')
prefix = prefix.replace('var data: [String: String] = [:]',
                        'var data: [String: String] = [:]; var modes: [String: Int] = [:]; var unknownPaths = Set<String>()')
prefix = prefix.replace('func fileExists(at path: String)',
                        'func pathPresence(at path: String) -> HelperPathPresence { unknownPaths.contains(path) ? .unknown : (data[path] == nil ? .absent : .present) }\n    func fileExists(at path: String)')
prefix = prefix.replace('try beforeWrite?(path, text); data[path] = text;',
                        'try beforeWrite?(path, text); modes[path] = mode; data[path] = text;')
prefix = prefix.replace('func run(_ command: CommandSpec) throws -> CommandResult {',
                        'func run(_ command: CommandSpec) throws -> CommandResult {\n        calls += 1')
prefix = prefix.replace('runner: runner, firewall: pf)', 'runner: runner, firewall: pf, dateProvider: Clock.shared)')

HARNESS = r'''
final class Clock: DateProviding, @unchecked Sendable {
    static let shared = Clock()
    var seconds: TimeInterval = 1_800_000_000
    var now: Date { Date(timeIntervalSince1970: seconds) }
}
final class Identities: ProcessInspecting, @unchecked Sendable {
    var values: [Int32: String] = [123: "fixture-start-1", 124: "fixture-start-2", 125: "fixture-start-3"]
    func processIdentity(pid: Int32) -> String? { values[pid] }
}
final class Auth: PeerAuthenticating, @unchecked Sendable {
    var allowed = true
    func authenticate(_ peer: PeerCredentials) -> Bool { allowed && peer.auditToken == Data([7]) }
}
final class Log: HelperLogging, @unchecked Sendable {
    var messages: [String] = []
    func info(_ c: String, _ m: String) { messages.append(m) }
    func warn(_ c: String, _ m: String) { messages.append(m) }
    func error(_ c: String, _ m: String) { messages.append(m) }
}
let transferPath = paths.helperDirectory + "/protected-owner-transfer.state"
let receiptPath = paths.helperDirectory + "/replacement-commit-receipt.state"
let transaction = "E63DCEBD-109A-4C45-A23C-3F32BF42597A"
// Test-only capability; never a production token/key/identity.
let capability = String(repeating: "ab", count: 32)
final class RestartFixture {
    let f = Fixture(), ids = Identities(), auth = Auth(), log = Log()
    var runtime: HelperRuntime!
    let kind: String
    init(_ kind: String = "receipt", phase: String = "awaiting-handshake") throws {
        self.kind = kind
        Clock.shared.seconds = 1_800_000_000
        var session = f.source
        if kind == "receipt" || phase != "prepared" {
            session.interfaceName = "utun8"; session.routeInterface = "utun8"
            session.endpoint = "198.51.100.8:51820"; session.latestHandshake = 1000
            f.files.data[paths.activeConfigPath] = candidateConfig
            f.files.data[paths.amneziaNamePath(for: "active")] = "utun8"
            f.files.data[paths.amneziaSocketPath(for: "utun8")] = "inert"; f.runner.currentIF = "utun8"
        }
        try HelperStateStore(fileSystem: f.files, paths: paths).persistSession(session)
        let request = try ProtectedReplacementRequest(metadata: metadata.split(separator: " ").map(String.init))
        if kind == "receipt" {
            let owner = OwnerSession(payload: f.files.data[paths.ownerSessionPath]!)!
            let receipt = ProtectedReplacementCommitReceipt(request: request, owner: owner,
                latestHandshake: 1000, handshakeNotBefore: 900, sourceLatestHandshake: 1)
            f.files.data[receiptPath] = try receipt.encoded()
        } else {
            var journal = ProtectedReplacementJournal(ownerPID: 123, sourceSession: f.source.payload,
                sourceConfig: sourceConfig, sourceSHA256: digest(sourceConfig), candidateConfig: candidateConfig,
                candidateSHA256: digest(candidateConfig), dnsBaseline: dnsBaseline,
                ownerSession: f.files.data[paths.ownerSessionPath])
            journal.transactionID = transaction; journal.phase = phase
            if phase != "prepared" { journal.handshakeNotBefore = 900 }
            f.files.data[journalPath] = try journal.encoded()
        }
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
    func authorize() async throws {
        let reply = await send("protected-authorize-restart", input: input)
        try check(reply.hasPrefix("restart-authorized "), "live owner authorization persisted")
        try check(!reply.contains(capability), "capability not echoed")
    }
    func noNetwork(_ calls: Int = 0) throws {
        try check(f.runner.calls == calls && f.runner.up == 0 && f.runner.down == 0,
            "ownership work invokes no command runner")
        try check(f.pf.enables == 0 && f.pf.disables == 0 && f.pf.updates == 0 && f.pf.active,
            "PF protection unchanged")
        try check(f.files.data[paths.dnsStatePath] == dnsBaseline, "DNS baseline unchanged")
    }
    func assertAdopted(_ reply: String) throws {
        try check(reply.hasPrefix("owner-transferred ") && !reply.contains("committed "), "transfer is not commit proof")
        let owner = OwnerSession(payload: f.files.data[paths.ownerSessionPath]!)!
        let session = HelperSession(payload: f.files.data[paths.sessionStatePath]!)!
        try check(owner.pid == 124 && owner.identity == "fixture-start-2" && owner.token != "fixture-intent"
            && session.ownerPID == 124, "new actual peer with fresh helper token")
        try check(reply.contains("owner_token_sha256=" + digest(owner.token)) && !reply.contains(owner.token), "public new-owner binding only")
        if kind == "receipt" {
            let receipt = try ProtectedReplacementCommitReceipt.decode(f.files.data[receiptPath]!)
            try check(receipt.ownerPID == 124 && receipt.ownerIdentity == owner.identity
                && receipt.ownerTokenSHA256 == digest(owner.token) && receipt.latestHandshake == 1000,
                "receipt owner changes without weakening handshake proof")
        } else {
            let journal = try ProtectedReplacementJournal.decode(f.files.data[journalPath]!)
            try check(journal.ownerPID == 124 && journal.ownerSession == owner.payload
                && HelperSession(payload: journal.sourceSession)?.ownerPID == 124, "all journal owner bindings transferred")
        }
        try noNetwork()
    }
}
var cases = 0, failures = 0
func test(_ name: String, _ body: () async throws -> Void) async {
    cases += 1
    do { try await body(); print("protected_owner_transfer \(name)=PASS") }
    catch { failures += 1; print("protected_owner_transfer \(name)=FAIL \(error.localizedDescription)") }
    fflush(stdout)
}
Task {
    for kind in ["receipt", "journal"] {
        await test(kind + "-explicit-transfer") {
            let p = try RestartFixture(kind); try await p.authorize()
            p.ids.values.removeValue(forKey: 123); p.restart()
            try await p.runtime.bootstrap(); await p.runtime.runOwnerWatchdogTick(); await p.runtime.runRouteWatchdogTick()
            try p.noNetwork()
            let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
            try p.assertAdopted(reply)
            let replay = await p.send("protected-adopt-restart", input: p.input, pid: 124)
            try check(replay == reply, "lost ACK retry by exact same process is idempotent")
            let other = await p.send("protected-adopt-restart", input: p.input, pid: 125)
            try check(other.hasPrefix("error:"), "capability cannot transfer twice")
            let old = await p.send("protected-snapshot", pid: 123)
            try check(old.hasPrefix("error:"), "old process loses protected authority")
            try p.noNetwork()
        }
    }
    await test("prepared-journal-transfer") {
        let p = try RestartFixture("journal", phase: "prepared"); try await p.authorize()
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try p.assertAdopted(reply)
        let journal = try ProtectedReplacementJournal.decode(p.f.files.data[journalPath]!)
        try check(journal.phase == "prepared" && journal.handshakeNotBefore == nil
            && p.f.files.data[paths.activeConfigPath] == sourceConfig, "prepared source and phase unchanged")
    }
    await test("authorization-metadata-only-and-retry") {
        let p = try RestartFixture(); try await p.authorize()
        let record = p.f.files.data[transferPath]!
        try await p.authorize()
        try check(p.f.files.data[transferPath] == record && p.f.files.modes[transferPath] == 0o600,
            "authorization retry preserves original expiry and record")
        try check(!record.contains(capability) && !record.contains("PrivateKey") && !record.contains("[Peer]"),
            "only capability digest and bounded owner metadata persist")
        try p.noNetwork()
    }
    for verb in ["up", "down", "shutdown", "repair", "attach-owner", "antileak-off",
                 "protected-snapshot", "protected-receipt", "protected-commit", "protected-recover"] {
        await test("authorized-fences-" + verb) {
            let p = try RestartFixture(); try await p.authorize()
            let input = verb == "attach-owner" ? "owner_pid=123" : (verb.hasPrefix("protected-") && verb != "protected-snapshot" ? p.metadata : nil)
            let reply = await p.send(verb, input: input)
            try check(reply.hasPrefix("error:") && !reply.contains(capability), "pending ownership transfer blocks conflicting operations")
            p.ids.values.removeValue(forKey: 123)
            await p.runtime.runOwnerWatchdogTick(); await p.runtime.recoverStrandedAntiLeak(); await p.runtime.resumeOwnerWatchdog()
            try p.noNetwork()
        }
    }
    for kind in ["unauthenticated", "wrong-uid", "wrong-pid", "signature", "missing-identity", "old-pid-reuse", "expired", "clock-backwards",
                 "wrong-capability", "wrong-tuple", "duplicate", "unknown-field", "active-bytes", "dns-bytes", "owner-token",
                 "session-bytes", "receipt-bytes", "corrupt", "unreadable", "unknown-presence"] {
        await test("adopt-reject-" + kind) {
            let p = try RestartFixture(); try await p.authorize(); let ownerBefore = p.f.files.data[paths.ownerSessionPath]
            var input = p.input
            switch kind {
            case "signature": p.auth.allowed = false
            case "missing-identity": p.ids.values.removeValue(forKey: 124)
            case "old-pid-reuse": p.ids.values[123] = "reused-old-pid"
            case "expired": Clock.shared.seconds += 121
            case "clock-backwards": Clock.shared.seconds -= 1
            case "wrong-capability": input = input.replacingOccurrences(of: capability, with: String(repeating: "cd", count: 32))
            case "wrong-tuple": input = input.replacingOccurrences(of: transaction, with: "A63DCEBD-109A-4C45-A23C-3F32BF42597A")
            case "duplicate": input += " restart_capability=" + capability
            case "unknown-field": input += " extra=private-test-capability"
            case "active-bytes": p.f.files.data[paths.activeConfigPath] = sourceConfig
            case "dns-bytes": p.f.files.data[paths.dnsStatePath] = "changed"
            case "owner-token": p.f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "changed", identity: "fixture-start-1").payload
            case "session-bytes": p.f.files.data[paths.sessionStatePath]! += "unknown=true\n"
            case "receipt-bytes": p.f.files.data[receiptPath] = "{}\n"
            case "corrupt": p.f.files.data[transferPath] = "{}\n"
            case "unreadable": p.f.files.beforeRead = { if $0 == transferPath { throw HelperError.io("injected read") } }
            case "unknown-presence": p.f.files.unknownPaths.insert(transferPath)
            default: break
            }
            let reply = await p.send("protected-adopt-restart", input: input, pid: 124,
                uid: kind == "wrong-uid" ? 502 : 501, authenticated: kind != "unauthenticated",
                forwardedPID: kind == "wrong-pid" ? 125 : nil)
            try check(reply.hasPrefix("error:") && !reply.contains(capability), "unproved transfer denied and redacted")
            if kind != "owner-token" { try check(p.f.files.data[paths.ownerSessionPath] == ownerBefore, "denial does not change owner") }
            try check(p.f.files.data[transferPath] != nil, "denial preserves authorization evidence")
            try check(!p.log.messages.joined().contains(capability), "capability absent from logs")
            if kind != "dns-bytes" { try p.noNetwork() }
        }
    }
    for kind in ["missing-proof", "wrong-tuple", "dead-owner", "wrong-peer", "unknown-transfer", "write", "after-rename", "readback"] {
        await test("authorize-reject-" + kind) {
            let p = try RestartFixture(); var input = p.input
            switch kind {
            case "missing-proof": p.f.files.data.removeValue(forKey: receiptPath)
            case "wrong-tuple": input = input.replacingOccurrences(of: transaction, with: "A63DCEBD-109A-4C45-A23C-3F32BF42597A")
            case "dead-owner": p.ids.values.removeValue(forKey: 123)
            case "unknown-transfer": p.f.files.unknownPaths.insert(transferPath)
            case "write": p.f.files.beforeWrite = { path, _ in if path == transferPath { throw HelperError.io("injected write") } }
            case "after-rename": p.f.files.afterWrite = { path, _ in if path == transferPath { throw HelperError.io("injected sync") } }
            case "readback": p.f.files.afterWrite = { path, _ in if path == transferPath { p.f.files.data[path] = "{}\n" } }
            default: break
            }
            let reply = await p.send("protected-authorize-restart", input: input, pid: kind == "wrong-peer" ? 124 : 123)
            try check(reply.hasPrefix("error:"), "no authorization without verified old owner and durable record")
            try p.noNetwork()
        }
    }
    for point in ["prepared-record", "owner", "session", "evidence", "completed-record"] {
        for afterRename in [false, true] {
            await test("adopt-io-" + point + (afterRename ? "-sync" : "-write")) {
                let p = try RestartFixture(); try await p.authorize(); var fired = false
                let fail: (String, String) throws -> Void = { path, text in
                    let selected = (point == "prepared-record" && path == transferPath && text.contains("\"phase\":\"adopting\""))
                        || (point == "completed-record" && path == transferPath && text.contains("\"phase\":\"transferred\""))
                        || (point == "owner" && path == paths.ownerSessionPath)
                        || (point == "session" && path == paths.sessionStatePath)
                        || (point == "evidence" && path == receiptPath)
                    if selected && !fired { fired = true; throw HelperError.io("injected transfer persistence") }
                }
                if afterRename { p.f.files.afterWrite = fail } else { p.f.files.beforeWrite = fail }
                let first = await p.send("protected-adopt-restart", input: p.input, pid: 124)
                try check(first.hasPrefix("error:") && fired, "no ACK after persistence fault")
                p.f.files.beforeWrite = nil; p.f.files.afterWrite = nil; p.restart()
                let second = await p.send("protected-adopt-restart", input: p.input, pid: 124)
                try p.assertAdopted(second)
            }
        }
    }
    await test("partial-transfer-does-not-follow-next-dead-pid") {
        let p = try RestartFixture(); try await p.authorize()
        p.f.files.beforeWrite = { path, _ in if path == paths.sessionStatePath { throw HelperError.io("injected partial write") } }
        let first = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(first.hasPrefix("error:"), "partial transaction remains pending")
        p.f.files.beforeWrite = nil; p.ids.values.removeValue(forKey: 124); p.restart()
        let second = await p.send("protected-adopt-restart", input: p.input, pid: 125)
        try check(second.hasPrefix("error:"), "another process cannot inherit an in-flight adoption")
        try await p.runtime.bootstrap(); await p.runtime.runOwnerWatchdogTick(); try p.noNetwork()
    }
    await test("old-owner-explicit-cancel-expired-authorization") {
        let p = try RestartFixture(); try await p.authorize(); Clock.shared.seconds += 121
        let reply = await p.send("protected-cancel-restart", input: p.input)
        try check(reply.hasPrefix("restart-cancelled ") && p.f.files.data[transferPath] == nil, "only original live owner can cancel expired unused intent")
        try p.noNetwork()
    }
    await test("cancel-cannot-abandon-partial-transfer") {
        let p = try RestartFixture(); try await p.authorize()
        p.f.files.beforeWrite = { path, _ in if path == paths.ownerSessionPath { throw HelperError.io("injected partial owner write") } }
        _ = await p.send("protected-adopt-restart", input: p.input, pid: 124); p.f.files.beforeWrite = nil
        let reply = await p.send("protected-cancel-restart", input: p.input)
        try check(reply.hasPrefix("error:") && p.f.files.data[transferPath] != nil, "prepared adoption fence cannot be cancelled")
        try p.noNetwork()
    }
    await test("no-authorization-never-adopts-dead-owner") {
        let p = try RestartFixture(); p.ids.values.removeValue(forKey: 123)
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(reply.hasPrefix("error:") && OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)?.pid == 123,
            "metadata or dead PID is not permission")
        try p.noNetwork()
    }
    await test("transferred-receipt-still-needs-current-proof") {
        let p = try RestartFixture(); try await p.authorize()
        let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124); try p.assertAdopted(reply)
        let owner = OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!
        let metadata = p.metadata.replacingOccurrences(of: digest("fixture-intent"), with: digest(owner.token))
        let proof = await p.send("protected-receipt", input: metadata, pid: 124)
        try check(proof.hasPrefix("committed "), "new owner can request separate authenticated commit proof")
        p.f.runner.badCandidateDNS = true
        let stale = await p.send("protected-receipt", input: metadata, pid: 124)
        try check(stale.hasPrefix("error:"), "ownership receipt does not override changed DNS")
        try check(p.f.runner.up == 0 && p.f.runner.down == 0 && p.f.pf.updates == 0, "proof stays read-only")
    }
    await test("misrouted-capability-is-redacted") {
        let p = try RestartFixture()
        let reply = await p.send("down", input: "restart_capability=" + capability)
        try check(reply.hasPrefix("error:") && !reply.contains(capability) && !p.log.messages.joined().contains(capability),
            "legacy parser errors cannot leak transfer capability")
        try p.noNetwork()
    }
    for point in ["signature", "new-start-identity", "expiry", "old-start-identity"] {
        await test("identity-rechecked-after-prepared-write-" + point) {
            let p = try RestartFixture(); try await p.authorize()
            p.f.files.afterWrite = { path, text in
                if path == transferPath && text.contains("\"phase\":\"adopting\"") {
                    switch point {
                    case "signature": p.auth.allowed = false
                    case "new-start-identity": p.ids.values[124] = "reused-new-pid"
                    case "expiry": Clock.shared.seconds += 121
                    default: p.ids.values[123] = "reused-old-pid"
                    }
                }
            }
            let reply = await p.send("protected-adopt-restart", input: p.input, pid: 124)
            try check(reply.hasPrefix("error:") && OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)?.pid == 123,
                "identity and expiry change stops before dependent owner write")
            try check(p.f.files.data[transferPath]?.contains("\"phase\":\"adopting\"") == true,
                "prepared authority retained instead of implicit adoption")
            try p.noNetwork()
        }
    }
    await test("fresh-current-owner-may-authorize-next-restart") {
        let p = try RestartFixture(); try await p.authorize()
        let first = await p.send("protected-adopt-restart", input: p.input, pid: 124); try p.assertAdopted(first)
        let owner = OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)!
        let nextInput = p.input.replacingOccurrences(of: digest("fixture-intent"), with: digest(owner.token))
            .replacingOccurrences(of: capability, with: String(repeating: "cd", count: 32))
        let authorized = await p.send("protected-authorize-restart", input: nextInput, pid: 124)
        try check(authorized.hasPrefix("restart-authorized "), "fresh consent replaces completed receipt")
        let next = await p.send("protected-adopt-restart", input: nextInput, pid: 125)
        try check(next.hasPrefix("owner-transferred ") && OwnerSession(payload: p.f.files.data[paths.ownerSessionPath]!)?.pid == 125,
            "second restart requires new current-owner consent")
        let stale = await p.send("protected-adopt-restart", input: p.input, pid: 124)
        try check(stale.hasPrefix("error:"), "old capability cannot replay into next intent")
        try p.noNetwork()
    }
    for kind in ["good", "mode", "symlink", "hardlink", "oversized", "unknown-field", "duplicate-field"] {
        await test("actual-private-files-" + kind) {
            let p = try RestartFixture(); try await p.authorize()
            // Python creates/resolves this existing parent before Swift binds
            // any not-yet-created child. Do not rely on Foundation temp aliases
            // or weaken production's descriptor-based no-follow checks.
            let parent = CommandLine.arguments[1]
            precondition(parent.hasPrefix("/private/") || parent.hasPrefix("/Volumes/"))
            let root = parent + "/owner-transfer-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: root) }
            let local = LocalFileSystem(), layout = isolatedPaths(root)
            let localStore = HelperStateStore(fileSystem: local, paths: layout, dateProvider: Clock.shared)
            try localStore.ensureDirectories()
            let copies = [(paths.ownerSessionPath, layout.ownerSessionPath), (paths.sessionStatePath, layout.sessionStatePath),
                (paths.interfacePath, layout.interfacePath), (paths.endpointPath, layout.endpointPath),
                (paths.activeConfigPath, layout.activeConfigPath), (paths.dnsStatePath, layout.dnsStatePath),
                (receiptPath, layout.helperDirectory + "/replacement-commit-receipt.state"),
                (transferPath, layout.helperDirectory + "/protected-owner-transfer.state")]
            for (source, target) in copies { try local.writeTextAtomically(p.f.files.data[source]!, to: target, mode: 0o600) }
            let record = copies.last!.1, sibling = root + "/record-baseline"
            try local.writeTextAtomically(p.f.files.data[transferPath]!, to: sibling, mode: 0o600)
            switch kind {
            case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: record)
            case "symlink": try local.removeItem(at: record); try FileManager.default.createSymbolicLink(atPath: record, withDestinationPath: sibling)
            case "hardlink": try local.removeItem(at: record); try FileManager.default.linkItem(atPath: sibling, toPath: record)
            case "oversized": try local.writeTextAtomically(String(repeating: "x", count: 16_385), to: record, mode: 0o600)
            case "unknown-field": try local.writeTextAtomically(p.f.files.data[transferPath]!.replacingOccurrences(of: "{", with: "{\"extra\":true,"), to: record, mode: 0o600)
            case "duplicate-field": try local.writeTextAtomically(p.f.files.data[transferPath]!.replacingOccurrences(of: "{", with: "{\"phase\":\"authorized\","), to: record, mode: 0o600)
            default: break
            }
            let controller = SystemTunnelController(fileSystem: local, paths: layout, runner: p.f.runner,
                firewall: p.f.pf, dateProvider: Clock.shared)
            let runtime = HelperRuntime(store: localStore, tunnelController: controller, firewallController: p.f.pf,
                processInspector: p.ids, dateProvider: Clock.shared, logger: p.log, protectedPeerAuthenticator: p.auth)
            p.ids.values.removeValue(forKey: 123)
            try await runtime.bootstrap(); await runtime.runOwnerWatchdogTick(); await runtime.runRouteWatchdogTick()
            let reply = await runtime.handle(commandLine: "protected-adopt-restart " + p.input, peerPID: 124,
                authenticatedPeer: PeerCredentials(pid: 124, auditToken: Data([7]), effectiveUID: 501)).payload
            if kind == "good" {
                try check(reply.hasPrefix("owner-transferred ") && localStore.loadOwnerSession()?.pid == 124,
                    "actual atomic private writer/readback and owned-file transfer")
                let mode = try FileManager.default.attributesOfItem(atPath: layout.ownerSessionPath)[.posixPermissions] as? NSNumber
                try check(mode?.intValue == 0o600, "new real owner file remains private")
            } else {
                try check(reply.hasPrefix("error:") && localStore.loadOwnerSession()?.pid == 123,
                    "unsafe real state rejected before ownership writes")
            }
            try p.noNetwork()
            try check(try local.readPrivateText(at: layout.activeConfigPath, maxBytes: 1_048_576) == candidateConfig,
                "actual canonical material untouched")
        }
    }
    print("protected_owner_transfer_matrix cases=\(cases) failures=\(failures) live_network_commands=0 signature_acceptance=not_claimed")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''

scratch = Path(os.environ.get("TMPDIR", str(ROOT.parent / ".vex-tmp"))).resolve()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="protected-owner-transfer-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(prefix + HARNESS)
    command = ["rtk", "proxy", "swiftc", "-swift-version", "5",
               *map(str, sorted(CORE.glob("*.swift"))), str(directory / "main.swift"),
               "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm", "-o", str(directory / "probe")]
    built = subprocess.run(command, timeout=180)
    if built.returncode:
        raise SystemExit(built.returncode)
    data = directory / "owned-files"
    data.mkdir(mode=0o700)
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe"), str(data.resolve())], timeout=120).returncode)

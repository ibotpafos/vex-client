#!/usr/bin/env python3
"""Authenticated production RPC/controller with exclusively inert network ports.

Optional source root permits the identical evaluator on pristine/rollback trees.
No installed helper/app, ProcessRunner, live route, DNS or PF is invoked.
"""
import ast
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
# Reuse only the literal fake-port definitions; never execute the other runner.
fixture_file = Path(__file__).with_name("test_macos_protected_replacement.py")
tree = ast.parse(fixture_file.read_text())
foundation = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == "HARNESS" for t in n.targets))
prefix = foundation.split("// Child processes only", 1)[0]
prefix = prefix.replace('var currentIF = "utun7", up = 0, down = 0',
                        'var currentIF = "utun7", up = 0, down = 0\n    var handshake: UInt64 = 1')
prefix = prefix.replace(r'\t1\t12\t13\t25', r'\t\(handshake)\t12\t13\t25')
prefix = prefix.replace('var data: [String: String] = [:]', 'var data: [String: String] = [:]; var writtenModes: [String:Int] = [:]')
prefix = prefix.replace('try beforeWrite?(path, text); data[path] = text;', 'try beforeWrite?(path, text); writtenModes[path]=mode; data[path] = text;')
HARNESS = r'''
final class ProcessIdentity: ProcessInspecting, @unchecked Sendable {
    var identity: String? = "fixture-start-1"
    var expectedPID: Int32 = 123
    func processIdentity(pid: Int32) -> String? { pid == expectedPID ? identity : nil }
}
final class Authentication: PeerAuthenticating, @unchecked Sendable {
    var allowed = true
    func authenticate(_ peer: PeerCredentials) -> Bool { allowed && peer.pid == 123 && peer.auditToken == Data([7]) }
}
struct Quiet: HelperLogging {
    func info(_ c: String, _ m: String) {}
    func warn(_ c: String, _ m: String) {}
    func error(_ c: String, _ m: String) {}
}
final class RPCFixture {
    let f = Fixture(), process = ProcessIdentity(), auth = Authentication()
    var runtime: HelperRuntime!
    var transaction = "E63DCEBD-109A-4C45-A23C-3F32BF42597A"
    init() throws {
        try HelperStateStore(fileSystem: f.files, paths: paths).persistSession(f.source)
        restart()
    }
    func restart() {
        #if AUTHENTICATED_PROTECTED_RPC
        runtime = HelperRuntime(store: HelperStateStore(fileSystem: f.files, paths: paths),
            tunnelController: f.controller, firewallController: f.pf, processInspector: process,
            logger: Quiet(), protectedPeerAuthenticator: auth)
        #else
        runtime = HelperRuntime(store: HelperStateStore(fileSystem: f.files, paths: paths),
            tunnelController: f.controller, firewallController: f.pf, processInspector: process, logger: Quiet())
        #endif
    }
    var metadata: String {
        "transaction_id=\(transaction) source_sha256=\(digest(sourceConfig)) candidate_sha256=\(digest(candidateConfig)) owner_token_sha256=\(digest("fixture-intent"))"
    }
    func send(_ command: String, authenticated: Bool = true, pid: Int32 = 123) async -> String {
        #if AUTHENTICATED_PROTECTED_RPC
        return await runtime.handle(commandLine: command, peerPID: pid,
            authenticatedPeer: authenticated ? PeerCredentials(pid: pid, auditToken: Data([7]), effectiveUID: 501) : nil).payload
        #else
        return await runtime.handle(commandLine: command, peerPID: pid).payload
        #endif
    }
    func replace() async throws {
        try await authorize()
        let response = await send("protected-replace " + metadata)
        try check(response.hasPrefix("ready transaction_id=" + transaction), "authenticated replacement ready")
        try check(f.files.data[journalPath]?.contains("awaiting-handshake") == true, "journal retained until fresh handshake")
        try f.protected()
    }
    func authorize() async throws {
        let response = await send("protected-snapshot")
        guard let field = response.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("transaction_id=") }) else {
            throw HelperError.io("authenticated snapshot grant missing")
        }
        transaction = String(field.dropFirst("transaction_id=".count))
    }
    func noMutation() throws {
        try f.protected()
        try check(f.runner.up == 0 && f.runner.down == 0 && f.pf.updates == 0, "no mutating commands")
        try check(f.files.data[paths.activeConfigPath] == sourceConfig, "source unchanged")
    }
}
var failures = 0, cases = 0
func test(_ name: String, _ body: () async throws -> Void) async {
    cases += 1
    do { try await body(); print("protected_rpc \(name)=PASS") }
    catch { failures += 1; print("protected_rpc \(name)=FAIL \(error.localizedDescription)") }
    fflush(stdout)
}

// Only this unprivileged child opens a real, disposable AF_UNIX socket. Its
// filesystem, tunnel, DNS, route and PF dependencies remain the memory ports
// above. Kernel audit-token/PID forwarding is exercised without trusting a
// production identity or calling the installed helper.
struct SocketPeer: PeerAuthenticating {
    let expectedPID: Int32
    let denied: Bool
    func authenticate(_ peer: PeerCredentials) -> Bool {
        !denied && peer.pid == expectedPID && peer.effectiveUID == geteuid()
            && peer.auditToken.count == MemoryLayout<audit_token_t>.size
    }
}
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--serve" {
    do {
        let directory = CommandLine.arguments[2]
        guard let expectedPID = Int32(CommandLine.arguments[3]), expectedPID > 0, geteuid() != 0 else {
            throw HelperError.io("socket fixture requires its unprivileged parent")
        }
        let mode = CommandLine.arguments[4]
        let p = try RPCFixture()
        p.process.expectedPID = expectedPID
        if mode != "foreign-owner" {
            p.f.source.ownerPID = expectedPID
            p.f.files.data[paths.ownerSessionPath] = OwnerSession(pid: expectedPID,
                token: "fixture-intent", identity: "fixture-start-1").payload
            try HelperStateStore(fileSystem: p.f.files, paths: paths).persistSession(p.f.source)
        }
        // The fake source handshake is 1; only the fake cutover makes it fresh.
        p.f.runner.onDown = { p.f.runner.handshake = UInt64(Date().timeIntervalSince1970) }
        #if AUTHENTICATED_PROTECTED_RPC
        p.runtime = HelperRuntime(store: HelperStateStore(fileSystem: p.f.files, paths: paths),
            tunnelController: p.f.controller, firewallController: p.f.pf,
            processInspector: p.process, logger: Quiet(),
            protectedPeerAuthenticator: SocketPeer(expectedPID: expectedPID, denied: mode == "runtime-deny"))
        #endif
        let authenticator: any PeerAuthenticating = mode == "system-peer"
            ? SystemPeerAuthenticator()
            : SocketPeer(expectedPID: expectedPID, denied: mode == "server-deny")
        let digests = digest(sourceConfig) + " " + digest(candidateConfig) + " " + digest("fixture-intent")
        try Data(digests.utf8).write(to: URL(fileURLWithPath: directory + "/fixture-digests"))
        let server = UnixSocketServer(socketPath: directory + "/server.sock", logger: Quiet(), authenticator: authenticator)
        try server.run(runtime: p.runtime)
    } catch {
        fputs("socket fixture setup failed\n", stderr)
        exit(2)
    }
    exit(0)
}
Task {

    let receiptPath=paths.helperDirectory+"/replacement-commit-receipt.state"
    func committedFixture() async throws -> RPCFixture {
        let p=try RPCFixture();try await p.replace();p.f.runner.handshake=UInt64(Date().timeIntervalSince1970)
        let committed=await p.send("protected-commit "+p.metadata)
        try check(committed.hasPrefix("committed transaction_id="),"fixture committed")
        return p
    }
    await test("durable-receipt-before-journal-removal") {
        let p=try RPCFixture();try await p.replace();p.f.runner.handshake=UInt64(Date().timeIntervalSince1970)
        var presentBeforeRemoval=false
        p.f.files.beforeRemove={path in if path==journalPath {presentBeforeRemoval=p.f.files.data[receiptPath] != nil && p.f.files.writtenModes[receiptPath]==0o600}}
        let response=await p.send("protected-commit "+p.metadata)
        try check(response.hasPrefix("committed ") && presentBeforeRemoval,"receipt precedes journal deletion")
        try check(p.f.files.data[receiptPath]?.contains("PrivateKey")==false && p.f.files.data[receiptPath]?.contains("fixture-intent")==false,"metadata only; no config or owner token")
        try p.f.protected()
    }
    await test("durable-receipt-restart-and-read-only-replay") {
        let p=try await committedFixture();let up=p.f.runner.up,down=p.f.runner.down,pf=p.f.pf.updates;p.restart()
        let first=await p.send("protected-receipt "+p.metadata),second=await p.send("protected-receipt "+p.metadata)
        try check(first.hasPrefix("committed ") && first==second && first.contains("commit_receipt_protocol=1"),"persisted receipt replays after helper runtime recreation")
        try check(first.contains("source_sha256="+digest(sourceConfig)) && first.contains("candidate_sha256="+digest(candidateConfig)) && first.contains("owner_token_sha256="+digest("fixture-intent")),"exact transaction proof")
        try check(p.f.runner.up==up && p.f.runner.down==down && p.f.pf.updates==pf,"receipt lookup does not replace or recover")
        try p.f.protected()
    }
    for kind in ["id","source","candidate","owner"] {
        await test("durable-receipt-reject-"+kind) {
            let p=try await committedFixture();var metadata=p.metadata
            let old=kind=="id" ? p.transaction : (kind=="source" ? digest(sourceConfig) : (kind=="candidate" ? digest(candidateConfig) : digest("fixture-intent")))
            metadata=metadata.replacingOccurrences(of:old,with:kind=="id" ? "A63DCEBD-109A-4C45-A23C-3F32BF42597A" : digest("different-"+kind))
            let response=await p.send("protected-receipt "+metadata)
            try check(response.hasPrefix("error:"),"different tuple rejected")
            try check(p.f.files.data[paths.activeConfigPath]==candidateConfig && p.f.runner.up==1 && p.f.runner.down==1,"physical candidate untouched")
        }
    }
    for kind in ["missing","corrupt","unknown-fields","unreadable","active-bytes","route","dns","socket","handshake","future-handshake","owner-token","owner-start","unauthenticated"] {
        await test("durable-receipt-fence-"+kind) {
            let p=try await committedFixture()
            switch kind {
            case "missing":p.f.files.data.removeValue(forKey:receiptPath)
            case "corrupt":p.f.files.data[receiptPath]="{}\n"
            case "unknown-fields":if let text=p.f.files.data[receiptPath] {p.f.files.data[receiptPath]=text.replacingOccurrences(of:"{",with:"{\"unknown\":true,")}
            case "unreadable":p.f.files.beforeRead={path in if path==receiptPath {throw HelperError.io("injected receipt read")}}
            case "active-bytes":p.f.files.data[paths.activeConfigPath]=sourceConfig
            case "route":p.f.runner.badCandidateRoute=true
            case "dns":p.f.runner.badCandidateDNS=true
            case "socket":p.f.files.data.removeValue(forKey:paths.amneziaSocketPath(for:"utun8"))
            case "handshake":p.f.runner.handshake=1
            case "future-handshake":p.f.runner.handshake=UInt64(Date().timeIntervalSince1970)+3600
            case "owner-token":p.f.files.data[paths.ownerSessionPath]=OwnerSession(pid:123,token:"changed",identity:"fixture-start-1").payload
            case "owner-start":p.process.identity="new-start"
            default:break
            }
            let beforeUp=p.f.runner.up,beforeDown=p.f.runner.down,beforePF=p.f.pf.updates
            let response=await p.send("protected-receipt "+p.metadata,authenticated:kind != "unauthenticated")
            try check(response.hasPrefix("error:"),"unproven receipt rejected")
            try check(p.f.runner.up==beforeUp && p.f.runner.down==beforeDown && p.f.pf.updates==beforePF,"lookup is non-mutating")
        }
    }
    for kind in ["write","readback","delete-journal"] {
        await test("durable-receipt-io-"+kind+"-retains-recovery") {
            let p=try RPCFixture();try await p.replace();p.f.runner.handshake=UInt64(Date().timeIntervalSince1970)
            if kind=="write" {p.f.files.beforeWrite={path,_ in if path==receiptPath {throw HelperError.io("injected receipt write")}}}
            if kind=="readback" {p.f.files.afterWrite={path,_ in if path==receiptPath {p.f.files.data[path]="{}\n"}}}
            if kind=="delete-journal" {p.f.files.beforeRemove={path in if path==journalPath {throw HelperError.io("injected journal delete")}}}
            let response=await p.send("protected-commit "+p.metadata)
            try check(response.hasPrefix("error:") && p.f.files.data[journalPath]?.contains("committed")==true,"no success without durable receipt and cleanup")
            let lookup=await p.send("protected-receipt "+p.metadata)
            try check(lookup.hasPrefix("error:") && p.f.runner.up==1 && p.f.runner.down==1,"pending journal cannot be mistaken for acknowledged commit")
            try p.f.protected()
        }
    }
    await test("durable-receipt-owner-changes-during-read") {
        let p=try await committedFixture();var didChange=false
        p.f.files.beforeRead={path in if path==receiptPath && !didChange {didChange=true;p.f.files.data[paths.ownerSessionPath]=OwnerSession(pid:123,token:"changed",identity:"fixture-start-1").payload}}
        let response=await p.send("protected-receipt "+p.metadata)
        try check(response.hasPrefix("error:") && p.f.runner.up==1 && p.f.runner.down==1,"owner rechecked after suspension/read")
    }

    await test("snapshot-read-only") {
        let p = try RPCFixture(); let reply = await p.send("protected-snapshot")
        try check(reply.hasPrefix("protected_protocol=1 recovery_pending=false"), "protocol advertised")
        try check(reply.contains("source_sha256=" + digest(sourceConfig)), "source CAS identity")
        try check(!reply.contains("fixture-intent") && !reply.contains("PrivateKey"), "no secrets")
        try p.noMutation()
    }
    await test("replace-commit-fresh-handshake") {
        let p = try RPCFixture(); try await p.replace()
        p.f.runner.handshake = UInt64(Date().timeIntervalSince1970)
        let response = await p.send("protected-commit " + p.metadata)
        try check(response.hasPrefix("committed transaction_id=" + p.transaction), "fresh candidate committed")
        try check(p.f.files.data[journalPath] == nil, "committed journal removed")
        try check(p.f.files.data[paths.activeConfigPath] == candidateConfig, "candidate active")
        try p.f.protected()
    }
    for kind in ["missing", "old", "future"] {
        await test("reject-" + kind + "-handshake") {
            let p = try RPCFixture(); try await p.replace()
            p.f.runner.handshake = kind == "missing" ? 0 : (kind == "old" ? 1 : UInt64(Date().timeIntervalSince1970) + 3600)
            let response = await p.send("protected-commit " + p.metadata)
            try check(response.contains("awaiting fresh handshake"), "unproven handshake rejected")
            try check(p.f.files.data[journalPath] != nil, "recovery retained")
            try p.f.protected()
        }
    }
    await test("explicit-protected-recovery") {
        let p = try RPCFixture(); try await p.replace()
        let reply = await p.send("protected-recover " + p.metadata)
        try check(reply.hasPrefix("recovered transaction_id=" + p.transaction), "authenticated recovery")
        try p.f.restored()
    }
    await test("helper-restart-preserves-transaction") {
        let p = try RPCFixture(); try await p.replace(); p.restart()
        let before = p.f.runner.down; try await p.runtime.bootstrap()
        let snapshot = await p.send("protected-snapshot")
        try check(snapshot.contains("recovery_pending=true") && snapshot.contains(p.transaction), "restart snapshot")
        try check(p.f.runner.down == before, "bootstrap does not clean up")
        p.f.runner.handshake = UInt64(Date().timeIntervalSince1970)
        let reply = await p.send("protected-commit " + p.metadata)
        try check(reply.hasPrefix("committed "), "restart commit")
        try p.f.protected()
    }
    for command in ["down", "shutdown", "repair", "antileak-off", "up", "attach-owner owner_pid=123"] {
        await test("pending-fences-" + command.components(separatedBy: " ")[0]) {
            let p = try RPCFixture(); try await p.replace()
            let before = (p.f.runner.down, p.f.runner.up, p.f.pf.updates)
            let reply = await p.send(command)
            try check(reply.contains("recovery pending"), "ordinary operation fenced")
            await p.runtime.runOwnerWatchdogTick(); await p.runtime.runRouteWatchdogTick()
            try check(before == (p.f.runner.down, p.f.runner.up, p.f.pf.updates), "no ordinary/watchdog mutations")
            try p.f.protected()
        }
    }
    for kind in ["no-peer", "denied-peer", "wrong-peer", "dead-owner", "reused-pid", "owner-token", "source-digest", "candidate-digest", "duplicate", "unknown-field", "invalid-uuid"] {
        await test("reject-" + kind) {
            let p = try RPCFixture(); try await p.authorize(); var metadata = p.metadata
            switch kind {
            case "denied-peer": p.auth.allowed = false
            case "dead-owner": p.process.identity = nil
            case "reused-pid": p.process.identity = "different-start"
            case "owner-token": metadata = metadata.replacingOccurrences(of: digest("fixture-intent"), with: digest("different-intent"))
            case "source-digest": metadata = metadata.replacingOccurrences(of: digest(sourceConfig), with: digest("different-source"))
            case "candidate-digest": metadata = metadata.replacingOccurrences(of: digest(candidateConfig), with: digest("different-candidate"))
            case "duplicate": metadata += " transaction_id=" + p.transaction
            case "unknown-field": metadata += " secret=DO_NOT_LOG"
            case "invalid-uuid": metadata = metadata.replacingOccurrences(of: p.transaction, with: "wrong")
            default: break
            }
            let reply = await p.send("protected-replace " + metadata, authenticated: kind != "no-peer", pid: kind == "wrong-peer" ? 124 : 123)
            try check(reply.hasPrefix("error:"), "request rejected")
            try check(!reply.contains("DO_NOT_LOG"), "metadata never echoed")
            try p.noMutation()
        }
    }
    for point in ["lease", "after-down"] {
        for kind in ["process-exit", "token-change"] {
            await test("recheck-" + point + "-" + kind) {
                let p = try RPCFixture(); try await p.authorize()
                let invalidate = {
                    if kind == "process-exit" { p.process.identity = nil }
                    else { p.f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "new-intent", identity: "fixture-start-1").payload }
                }
                if point == "lease" {
                    p.f.files.afterWrite = { path, _ in if path == paths.operationLockPath { invalidate() } }
                } else { p.f.runner.onDown = invalidate }
                let reply = await p.send("protected-replace " + p.metadata)
                try check(reply.hasPrefix("error:"), "stale operation rejected")
                try check(p.f.runner.up == 0, "no stale candidate/rollback up")
                if point == "lease" { try p.noMutation() }
                else { try check(p.f.runner.down == 1 && p.f.files.data[journalPath] != nil, "interrupted journal retained") }
                try p.f.protected()
            }
        }
    }
    for verb in ["protected-commit", "protected-recover"] {
        for kind in ["wrong-transaction", "wrong-candidate", "no-peer", "dead-owner"] {
            await test(verb + "-" + kind) {
                let p = try RPCFixture(); try await p.replace()
                let before = (p.f.runner.down, p.f.runner.up, p.f.pf.updates)
                var metadata = p.metadata
                if kind == "wrong-transaction" { metadata = metadata.replacingOccurrences(of: p.transaction, with: UUID().uuidString) }
                if kind == "wrong-candidate" { metadata = metadata.replacingOccurrences(of: digest(candidateConfig), with: digest("different-candidate")) }
                if kind == "dead-owner" { p.process.identity = nil }
                let reply = await p.send(verb + " " + metadata, authenticated: kind != "no-peer")
                try check(reply.hasPrefix("error:"), "foreign finalization rejected")
                try check(before == (p.f.runner.down, p.f.runner.up, p.f.pf.updates) && p.f.files.data[journalPath] != nil, "foreign recovery makes no mutation")
                try p.f.protected()
            }
        }
    }
    await test("snapshot-supersedes-old-grant") {
        let p = try RPCFixture(); try await p.authorize(); let stale = p.metadata
        try await p.authorize()
        let reply = await p.send("protected-replace " + stale)
        try check(reply.contains("grant is absent, stale or consumed"), "superseded intent rejected")
        try p.noMutation()
    }
    await test("replacement-replay-after-recovery") {
        let p = try RPCFixture(); try await p.replace(); let stale = p.metadata
        let recovered = await p.send("protected-recover " + stale)
        try check(recovered.hasPrefix("recovered "), "source recovered")
        let before = (p.f.runner.up, p.f.runner.down)
        let replay = await p.send("protected-replace " + stale)
        try check(replay.contains("grant is absent, stale or consumed"), "consumed intent rejected")
        try check(before == (p.f.runner.up, p.f.runner.down), "replay makes no mutation")
        try p.f.restored()
    }
    print("protected_rpc_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''


def request(path: Path, command: bytes) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        client.sendall(command + b"\n")
        output = b""
        while b"\n" not in output:
            chunk = client.recv(4096)
            if not chunk:
                break
            output += chunk
        return output.decode()


def socket_matrix(binary: Path) -> int:
    cases, failures = 0, 0

    def check(name: str, passed: bool) -> None:
        nonlocal cases, failures
        cases += 1
        failures += not passed
        print(f"protected_socket {name}={'PASS' if passed else 'FAIL'}", flush=True)

    # Keep Darwin's sockaddr_un path below 104 bytes. Resolve the existing
    # root rather than relaxing the production secure-store no-follow policy.
    short_root = Path(os.environ.get("VEX_NATIVE_SOCKET_TEST_TMPDIR", "/private/tmp")).resolve()
    short_root.mkdir(parents=True, exist_ok=True)
    for mode in ("allow", "recover", "server-deny", "runtime-deny", "foreign-owner", "system-peer"):
        with tempfile.TemporaryDirectory(prefix="vex-rpc-", dir=short_root) as raw:
            directory = Path(raw)
            path = directory / "server.sock"
            assert len(str(path).encode()) < 104
            child = subprocess.Popen([str(binary), "--serve", str(directory), str(os.getpid()), mode],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not path.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not path.exists():
                    check(mode + "-fixture-start", False)
                    continue
                source, candidate, owner = (directory / "fixture-digests").read_text().split()
                snapshot = request(path, b"protected-snapshot")
                if mode in ("server-deny", "system-peer"):
                    check(mode + "-audit-peer-rejected", snapshot == "error: unauthenticated helper client\n")
                    continue
                status = request(path, b"status")
                if mode in ("runtime-deny", "foreign-owner"):
                    check(mode + "-protected-auth-rejected", snapshot == "error: protected operation requires the authenticated live owner\n")
                    check(mode + "-source-retained", "state=connected" in status and "endpoint=198.51.100.7:51820" in status)
                    continue
                fields = dict(part.split("=", 1) for part in snapshot.split() if "=" in part)
                valid = fields.get("source_sha256") == source and fields.get("owner_token_sha256") == owner
                transaction = fields.get("transaction_id", "E63DCEBD-109A-4C45-A23C-3F32BF42597A")
                metadata = f"transaction_id={transaction} source_sha256={source} candidate_sha256={candidate} owner_token_sha256={owner}"
                check(mode + "-authenticated-snapshot", valid and fields.get("recovery_pending") == "false")
                check(mode + "-snapshot-readonly", "endpoint=198.51.100.7:51820" in status and "leak_protection=armed" in status)
                malformed = request(path, b"protected-snapshot\0")
                check(mode + "-nul-frame-rejected", malformed.startswith("error:"))
                duplicate = request(path, ("protected-replace " + metadata + " transaction_id=" + transaction).encode())
                check(mode + "-duplicate-rejected", duplicate.startswith("error:") and "PrivateKey" not in duplicate)
                ready = request(path, ("protected-replace " + metadata).encode())
                check(mode + "-replacement-ready", ready == f"ready transaction_id={transaction} candidate_sha256={candidate}\n")
                pending = request(path, b"status")
                check(mode + "-pending-journal-visible", "recovery_pending=true" in pending)
                for verb in ("up", "down", "antileak-off", "shutdown"):
                    reply = request(path, verb.encode())
                    check(mode + "-pending-fences-" + verb, "protected replacement recovery pending" in reply and child.poll() is None)
                verb = "protected-recover" if mode == "recover" else "protected-commit"
                result = request(path, (verb + " " + metadata).encode())
                expected = "recovered" if mode == "recover" else "committed"
                check(mode + "-authenticated-finalize", result.startswith(expected + " transaction_id=" + transaction))
                final = request(path, b"status")
                endpoint = "198.51.100.7:51820" if mode == "recover" else "198.51.100.8:51820"
                check(mode + "-exact-final-state", "state=connected" in final and "endpoint=" + endpoint in final
                      and "leak_protection=armed" in final and "recovery_pending=true" not in final)
                if mode == "allow":
                    lookup = request(path, ("protected-receipt " + metadata).encode())
                    check(mode + "-durable-receipt", lookup.startswith("committed ") and "commit_receipt_protocol=1" in lookup
                          and "candidate_sha256=" + candidate in lookup and "PrivateKey" not in lookup)
                    replay_receipt = request(path, ("protected-receipt " + metadata).encode())
                    check(mode + "-receipt-repeatable-read", replay_receipt == lookup and lookup.startswith("committed "))
                replay = request(path, ("protected-replace " + metadata).encode())
                check(mode + "-consumed-grant-rejected", "grant is absent, stale or consumed" in replay)
            finally:
                # Signal only our retained Popen child, never any installed app,
                # helper, PID found by name, or network-owning process.
                if child.poll() is None:
                    child.terminate()
                stdout, stderr = child.communicate(timeout=10)
                if child.returncode not in (0, -15):
                    check(mode + "-child-exit", False)
                    print(stderr.decode(errors="replace"), file=sys.stderr, end="")
    print(f"protected_socket_matrix cases={cases} failures={failures} live_network_commands=0 signature_acceptance=not_claimed", flush=True)
    return 1 if failures else 0

scratch = Path(os.environ.get("TMPDIR", str(ROOT.parent / ".vex-tmp"))).resolve()
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="protected-rpc-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(prefix + HARNESS)
    define = ["-D", "AUTHENTICATED_PROTECTED_RPC"] if (CORE / "ProtectedReplacementRPC.swift").exists() else []
    command = ["rtk", "proxy", "swiftc", "-swift-version", "5", *define,
               *map(str, sorted(CORE.glob("*.swift"))), str(directory / "main.swift"),
               "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm", "-o", str(directory / "probe")]
    result = subprocess.run(command, timeout=180)
    if result.returncode:
        raise SystemExit(result.returncode)
    direct = subprocess.run(["rtk", "proxy", str(directory / "probe")], timeout=120).returncode
    sockets = socket_matrix(directory / "probe")
    raise SystemExit(direct or sockets)

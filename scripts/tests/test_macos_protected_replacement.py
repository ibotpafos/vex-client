#!/usr/bin/env python3
"""Real HelperCore, inert tunnel/PF ports and disposable filesystem/lease probes.

No ProcessRunner, live helper, app, API, route, DNS or PF command is executed.
The only child executables are swiftc and this test's own unprivileged probe.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
HARNESS = r'''
import Foundation
import Darwin
import CryptoKit

// Keep a failed test child from terminating the evidence-producing parent.
signal(SIGPIPE, SIG_IGN)

func isolatedPaths(_ root: String) -> HelperPathsLayout {
    let layout = HelperPathsLayout(helperDirectory: root, socketPath: root + "/helper.sock",
        ownerSessionPath: root + "/owner.state", operationLockPath: root + "/operation.lock",
        antileakStatePath: root + "/antileak.state", legacyAntileakStatePath: root + "/antileak.active",
        antileakAnchorPath: root + "/anchor", sessionStatePath: root + "/session.state",
        interfacePath: root + "/utun.name", endpointPath: root + "/endpoint.txt",
        runtimeDirectory: root + "/runtime", amneziaRuntimeDirectory: root + "/amnezia",
        awgQuickPath: root + "/quick", configPathFile: root + "/config-path",
        defaultConfigPath: root + "/next.conf", activeConfigPath: root + "/active.conf",
        dnsStatePath: root + "/dns-baseline.state", awgPath: root + "/awg", pfConfigPath: root + "/pf.conf")
    precondition(Mirror(reflecting: layout).children.allSatisfy {
        guard let path = $0.value as? String else { return false }
        return path == root || path.hasPrefix(root + "/")
    }, "every test path must be inside its isolated root")
    return layout
}

func check(_ value: Bool, _ label: String) throws {
    if !value { throw HelperError.io("assertion: " + label) }
}
func rejected(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

// All tunnel paths below are dictionary keys, never paths opened on this Mac.
final class Files: HelperFileSystem, @unchecked Sendable {
    var data: [String: String] = [:]
    var beforeRead: ((String) throws -> Void)?
    var beforeWrite: ((String, String) throws -> Void)?
    var afterWrite: ((String, String) throws -> Void)?
    var beforeRemove: ((String) throws -> Void)?
    func createDirectory(at path: String) throws {}
    func fileExists(at path: String) -> Bool { data[path] != nil }
    func fileSize(at path: String) -> UInt64? { data[path].map { UInt64($0.utf8.count) } }
    func modificationDate(at path: String) -> Date? { nil }
    func readText(at path: String) throws -> String {
        try beforeRead?(path)
        guard let text = data[path] else { throw HelperError.io("absent fixture") }
        return text
    }
    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws {
        try beforeWrite?(path, text); data[path] = text; try afterWrite?(path, text)
    }
    func removeItem(at path: String) throws { try beforeRemove?(path); data.removeValue(forKey: path) }
}
final class Firewall: PFFirewallControlling, @unchecked Sendable {
    var active = true, updates = 0, enables = 0, disables = 0
    var failures = Set<Int>()
    func antileakIsActive() -> Bool { active }
    func enable(endpoint: String, interfaceName: String) throws {
        enables += 1; throw HelperError.commandFailed("forbidden generic enable")
    }
    func disable() throws { disables += 1; throw HelperError.commandFailed("forbidden disable") }
    func updateWhileArmed(endpoint: String, interfaceName: String) throws {
        updates += 1
        guard active, !failures.contains(updates) else { throw HelperError.commandFailed("injected PF update failure") }
    }
}
let paths = isolatedPaths("/f")
let journalPath = "/f/replacement-journal.state"
let dnsBaseline = "pristine fixture DNS baseline\n"
func config(_ endpoint: String) -> String {
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    let peer = Data(repeating: 2, count: 32).base64EncodedString()
    return "[Interface]\nPrivateKey = \(key)\nAddress = 10.23.4.2/32\nDNS = 1.1.1.1\nJc = 4\nJmin = 50\nJmax = 1000\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n[Peer]\nPublicKey = \(peer)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25\n"
}
let sourceConfig = config("198.51.100.7:51820"), candidateConfig = config("198.51.100.8:51820")
final class Runner: CommandRunning, @unchecked Sendable {
    let files: Files
    var currentIF = "utun7", up = 0, down = 0
    var upResults: [Int32] = [], downResults: [Int32] = []
    var absentDownFails = false, badCandidateRoute = false, badCandidateDNS = false
    var onDown: (() throws -> Void)?
    var journalBeforeMutation = true
    init(_ files: Files) { self.files = files }
    func run(_ command: CommandSpec) throws -> CommandResult {
        if command.program == "/f/quick" {
            let action = command.arguments.first
            journalBeforeMutation = journalBeforeMutation && files.data[journalPath]?.contains(digest(sourceConfig)) == true
            if action == "down" {
                down += 1
                let status = downResults.isEmpty ? Int32(0) : downResults.removeFirst()
                if status != 0 { return .init(status: status, stderr: "TEST_SECRET") }
                if absentDownFails && files.data[paths.amneziaSocketPath(for: currentIF)] == nil {
                    return .init(status: 1)
                }
                files.data.removeValue(forKey: paths.amneziaSocketPath(for: currentIF))
                files.data.removeValue(forKey: paths.amneziaNamePath(for: "active"))
                try onDown?()
                return .init(status: 0)
            }
            if action == "up" {
                up += 1
                let status = upResults.isEmpty ? Int32(0) : upResults.removeFirst()
                if status != 0 { return .init(status: status, stderr: "TEST_SECRET") }
                currentIF = files.data[paths.activeConfigPath] == candidateConfig ? "utun8" : "utun9"
                files.data[paths.amneziaNamePath(for: "active")] = currentIF
                files.data[paths.amneziaSocketPath(for: currentIF)] = "inert"
                return .init(status: 0)
            }
        }
        if command.program == "/f/awg" {
            return .init(status: 0, stdout: "interface\npeer\tpsk\t198.51.100.8:51820\t0.0.0.0/0\t1\t12\t13\t25\n")
        }
        if command.program == "/sbin/route", command.arguments.contains("get") {
            return .init(status: 0, stdout: "interface: " + (badCandidateRoute && currentIF == "utun8" ? "en0" : currentIF) + "\n")
        }
        if command.program == "/usr/sbin/scutil", command.arguments == ["--dns"] {
            return .init(status: 0, stdout: "resolver #1\n nameserver[0] : " + (badCandidateDNS && currentIF == "utun8" ? "9.9.9.9" : "1.1.1.1") + "\n")
        }
        throw HelperError.commandFailed("unexpected inert-port command")
    }
}
final class Fixture {
    let files = Files(), pf = Firewall()
    let runner: Runner
    let controller: SystemTunnelController
    var source = HelperSession(interfaceName: "utun7", endpoint: "198.51.100.7:51820", ownerPID: 123,
        routeInterface: "utun7", socketExists: true, antiLeakArmed: true, latestHandshake: 1)
    init() {
        files.data[paths.configPathFile] = "/f/next.conf\n"
        files.data[paths.defaultConfigPath] = candidateConfig
        files.data[paths.activeConfigPath] = sourceConfig
        files.data[paths.amneziaNamePath(for: "active")] = "utun7"
        files.data[paths.amneziaSocketPath(for: "utun7")] = "inert"
        files.data[paths.dnsStatePath] = dnsBaseline
        files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "fixture-intent", identity: "fixture-start-1").payload
        runner = Runner(files)
        controller = SystemTunnelController(fileSystem: files, paths: paths, runner: runner, firewall: pf)
    }
    func replace(owner: Int32 = 123, hash: String = digest(sourceConfig)) throws -> HelperSession {
        try controller.replacePreservingAntiLeak(currentSession: source, ownerPID: owner, expectedConfigSHA256: hash)
    }
    func protected() throws {
        try check(pf.active && pf.enables == 0 && pf.disables == 0, "protection never disabled")
        try check(runner.journalBeforeMutation, "source journal before quick mutation")
    }
    func restored() throws {
        try protected()
        try check(files.data[paths.activeConfigPath] == sourceConfig, "source config restored")
        try check(files.data[paths.dnsStatePath] == dnsBaseline, "original DNS baseline preserved")
        try check(files.data[journalPath] == nil, "completed journal removed")
    }
}

// Child processes only contend on a private disposable file; never start helper.
if CommandLine.arguments.count == 3 && ["--hold-lease", "--crash-lease"].contains(CommandLine.arguments[1]) {
    let root = CommandLine.arguments[2], files = LocalFileSystem()
    let layout = isolatedPaths(root)
    let store = HelperStateStore(fileSystem: files, paths: layout)
    try store.withOperationLock(staleAfter: 120) {
        if CommandLine.arguments[1] == "--crash-lease" { _exit(0) }
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: layout.operationLockPath)
        print("READY"); fflush(stdout)
        _ = FileHandle.standardInput.readData(ofLength: 1)
    }
    exit(0)
}
var failures = 0, cases = 0
func test(_ name: String, _ body: () throws -> Void) {
    cases += 1
    do { try body(); print("protected_case \(name)=PASS") }
    catch { failures += 1; print("protected_case \(name)=FAIL \(error.localizedDescription)") }
    fflush(stdout)
}
test("success") {
    let f = Fixture(); let result = try f.replace(); try f.protected()
    try check(result.interfaceName == "utun8" && f.files.data[paths.activeConfigPath] == candidateConfig, "candidate committed")
    try check(f.files.data[journalPath] == nil && f.files.data[paths.dnsStatePath] == dnsBaseline, "journal/DNS")
}
for kind in ["wrong-owner", "wrong-source-hash", "bad-candidate", "missing-source-socket", "unarmed", "stale-owner", "unreadable-owner", "duplicate-owner", "pending-journal"] {
    test("admission-" + kind) {
        let f = Fixture()
        switch kind {
        case "bad-candidate": f.files.data[paths.defaultConfigPath] = "bad fixture"
        case "missing-source-socket": f.files.data.removeValue(forKey: paths.amneziaSocketPath(for: "utun7"))
        case "unarmed": f.source.antiLeakArmed = false
        case "stale-owner": f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 124, token: "other", identity: "other").payload
        case "unreadable-owner": f.files.beforeRead = { if $0 == paths.ownerSessionPath { throw HelperError.io("unreadable fixture owner") } }
        case "duplicate-owner": f.files.data[paths.ownerSessionPath]! += "pid=123\n"
        case "pending-journal": f.files.data[journalPath] = "existing evidence"
        default: break
        }
        try check(rejected { _ = try f.replace(owner: kind == "wrong-owner" ? 124 : 123,
            hash: kind == "wrong-source-hash" ? String(repeating: "0", count: 64) : digest(sourceConfig)) }, "reject invalid input")
        try check(f.runner.up == 0 && f.runner.down == 0 && f.pf.updates == 0, "admission before mutations")
        try check(f.files.data[paths.activeConfigPath] == sourceConfig, "source remains unchanged")
    }
}
for afterRename in [false, true] {
    test(afterRename ? "journal-directory-sync-failure" : "journal-write-failure") {
        let f = Fixture()
        let fail: (String, String) throws -> Void = { path, _ in
            if path == journalPath { throw HelperError.io("injected journal write failure") }
        }
        if afterRename { f.files.afterWrite = fail } else { f.files.beforeWrite = fail }
        try check(rejected { _ = try f.replace() }, "write failure propagated")
        try check(f.runner.up == 0 && f.runner.down == 0 && f.pf.updates == 0, "no mutation after journal failure")
        f.files.afterWrite = nil; f.files.beforeWrite = nil
        if afterRename {
            try check(f.files.data[journalPath] != nil, "renamed evidence retained")
            _ = try f.controller.recoverProtectedReplacement(ownerPID: 123)
            try check(f.runner.up == 0 && f.runner.down == 0, "prepared recovery must not stop source")
        }
        try f.restored()
    }
}
test("initial-pf-failure-prepared-recovery") {
    let f = Fixture(); f.pf.failures = [1]
    try check(rejected { _ = try f.replace() }, "PF refusal")
    try check(f.runner.up == 0 && f.runner.down == 0, "source untouched")
    _ = try f.controller.recoverProtectedReplacement(ownerPID: 123)
    try check(f.runner.up == 0 && f.runner.down == 0, "prepared recovery source untouched")
    try f.restored()
}
for kind in ["candidate-write", "candidate-up", "candidate-pf", "candidate-route", "candidate-dns", "session-write", "journal-remove"] {
    test("rollback-" + kind) {
        let f = Fixture(); var failed = false
        if kind == "candidate-up" { f.runner.upResults = [1, 0] }
        if kind == "candidate-pf" { f.pf.failures = [2] }
        if kind == "candidate-route" { f.runner.badCandidateRoute = true }
        if kind == "candidate-dns" { f.runner.badCandidateDNS = true }
        f.files.beforeWrite = { path, _ in
            if !failed && ((kind == "candidate-write" && path == paths.activeConfigPath) ||
                          (kind == "session-write" && path == paths.sessionStatePath)) {
                failed = true; throw HelperError.io("injected one-shot persistence error")
            }
        }
        f.files.beforeRemove = { path in
            if !failed && kind == "journal-remove" && path == journalPath {
                failed = true; throw HelperError.io("injected journal remove error")
            }
        }
        try check(rejected { _ = try f.replace() }, "failure reported")
        try f.restored()
        try check(f.runner.up >= 1 && f.runner.down >= 1, "actual inert-port rollback ran")
    }
}
for kind in ["owner-token", "owner-identity", "owner-disappeared", "source-cas", "dns-cas", "journal-cas"] {
    test("stale-fence-" + kind) {
        let f = Fixture()
        f.runner.onDown = {
            switch kind {
            case "owner-token": f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "new-intent", identity: "fixture-start-1").payload
            case "owner-identity": f.files.data[paths.ownerSessionPath] = OwnerSession(pid: 123, token: "fixture-intent", identity: "new-process-same-pid").payload
            case "owner-disappeared": f.files.data.removeValue(forKey: paths.ownerSessionPath)
            case "source-cas": f.files.data[paths.activeConfigPath] = config("198.51.100.99:51820")
            case "dns-cas": f.files.data[paths.dnsStatePath] = "external DNS change"
            case "journal-cas":
                f.files.data[journalPath] = f.files.data[journalPath]!.replacingOccurrences(of: "utun7", with: "utun77")
            default: break
            }
        }
        try check(rejected { _ = try f.replace() }, "stale transaction rejected")
        try f.protected()
        try check(f.runner.down == 1 && f.runner.up == 0 && f.files.data[journalPath] != nil, "stale command cannot mutate again")
    }
}
test("rollback-failure-and-explicit-restart-recovery") {
    let f = Fixture(); f.runner.upResults = [1]; f.runner.absentDownFails = true
    try check(rejected { _ = try f.replace() }, "failed candidate and absent cleanup reported")
    try f.protected(); try check(f.files.data[journalPath] != nil, "retain recovery evidence")
    let before = f.runner.up + f.runner.down
    try check(rejected { _ = try f.controller.recoverProtectedReplacement(ownerPID: 124) }, "wrong recovery owner")
    try check(f.runner.up + f.runner.down == before, "no stale-owner commands")
    // The operator has repaired the fake cleanup precondition; no automatic
    // global-kill/route cleanup fallback is permitted in production code.
    f.runner.absentDownFails = false
    let restarted = SystemTunnelController(fileSystem: f.files, paths: paths, runner: f.runner, firewall: f.pf)
    _ = try restarted.recoverProtectedReplacement(ownerPID: 123)
    try f.restored()
}

let tempRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("local-" + UUID().uuidString)
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }
ATOMIC_TESTS

test("lease-reentrant-exclusion") {
    let f = Files(), store = HelperStateStore(fileSystem: f, paths: paths)
    try store.withOperationLock(staleAfter: 0) {
        try check(store.operationInProgress(staleAfter: 0), "held beyond TTL")
        try check(rejected { try store.withOperationLock(staleAfter: 0) {} }, "reentrant contender rejected")
    }
    try store.withOperationLock(staleAfter: 0) {}
}
test("lease-concurrent-contenders-and-error-release") {
    let root = tempRoot.appendingPathComponent("threads").path
    let p = isolatedPaths(root), files = LocalFileSystem()
    let store = HelperStateStore(fileSystem: files, paths: p)
    let counterLock = NSLock(); var rejections = 0
    try store.withOperationLock(staleAfter: 0) {
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if rejected({ try store.withOperationLock(staleAfter: 0) {} }) {
                counterLock.lock(); rejections += 1; counterLock.unlock()
            }
        }
        try check(rejections == 16, "all simultaneous contenders excluded")
    }
    var before = stat(), after = stat()
    try check(lstat(p.operationLockPath + ".lease", &before) == 0, "lease inode persisted")
    try check(rejected { try store.withOperationLock(staleAfter: 0) { throw HelperError.io("test body failure") } }, "body error propagated")
    try store.withOperationLock(staleAfter: 0) {}
    try check(lstat(p.operationLockPath + ".lease", &after) == 0 && before.st_ino == after.st_ino, "lease inode not unlinked")
    try check((after.st_mode & 0o777) == 0o600, "lease is private")
}
test("lease-cross-process-expired-marker") {
    let root = tempRoot.appendingPathComponent("contenders").path
    let p = isolatedPaths(root)
    let store = HelperStateStore(fileSystem: LocalFileSystem(), paths: p)
    let child = Process(), input = Pipe(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--hold-lease", root]; child.standardInput = input; child.standardOutput = output
    try child.run()
    defer { try? input.fileHandleForWriting.write(contentsOf: Data([1])); try? input.fileHandleForWriting.close(); child.waitUntilExit() }
    let ready = output.fileHandleForReading.availableData
    try check(String(decoding: ready, as: UTF8.self).contains("READY"), "child holds lease")
    try check(store.operationInProgress(staleAfter: 0), "cross-process lease survives expired marker")
    try check(rejected { try store.withOperationLock(staleAfter: 0) {} }, "cross-process contender rejected")
}
test("lease-process-crash-immediate-recovery") {
    let root = tempRoot.appendingPathComponent("crash").path
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--crash-lease", root]; try child.run(); child.waitUntilExit()
    try check(child.terminationStatus == 0, "test process exited")
    let p = isolatedPaths(root)
    let store = HelperStateStore(fileSystem: LocalFileSystem(), paths: p)
    try store.withOperationLock(staleAfter: 120) {}
    try check(!store.operationInProgress(staleAfter: 120), "crashed kernel lease recovered without TTL wait")
}
for kind in ["live-legacy", "malformed-legacy", "symlink-lease"] {
    test("lease-reject-" + kind) {
        let root = tempRoot.appendingPathComponent(kind).path
        let p = isolatedPaths(root)
        let files = LocalFileSystem(), store = HelperStateStore(fileSystem: files, paths: p)
        try store.ensureDirectories()
        if kind == "symlink-lease" {
            let target = root + "/other"; try files.writeTextAtomically("pristine", to: target, mode: 0o600)
            try FileManager.default.createSymbolicLink(atPath: p.operationLockPath + ".lease", withDestinationPath: target)
        } else {
            try files.writeTextAtomically(kind == "live-legacy" ? "pid=\(getpid())\n" : "unparseable legacy marker\n", to: p.operationLockPath, mode: 0o600)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: p.operationLockPath)
        }
        try check(rejected { try store.withOperationLock(staleAfter: 0) {} }, "unsafe marker/lease rejected")
    }
}
print("protected_replacement_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
exit(failures == 0 ? 0 : 1)
'''

ATOMIC_TESTS = r'''
for kind in ["success-percent-path", "file-sync-failure", "directory-sync-failure", "interrupted-sync", "rename-failure", "parent-symlink"] {
    test("atomic-" + kind) {
        let dir = tempRoot.appendingPathComponent(kind + "-%20")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("record").path
        let pristine = LocalFileSystem(); try pristine.writeTextAtomically("pristine", to: target, mode: 0o600)
        var interrupted = false
        let files = LocalFileSystem(syncDescriptor: { fd in
            var s = stat(); guard fstat(fd, &s) == 0 else { return -1 }
            let directory = (s.st_mode & S_IFMT) == S_IFDIR
            if (kind == "file-sync-failure" && !directory) || (kind == "directory-sync-failure" && directory) {
                errno = EIO; return -1
            }
            if kind == "interrupted-sync" && !interrupted { interrupted = true; errno = EINTR; return -1 }
            return Darwin.fsync(fd)
        })
        var writeTarget = target
        if kind == "rename-failure" {
            try FileManager.default.removeItem(atPath: target)
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        }
        if kind == "parent-symlink" {
            let alias = tempRoot.appendingPathComponent("alias").path
            try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: dir.path)
            writeTarget = alias + "/record"
        }
        let failed = rejected { try files.writeTextAtomically("complete replacement", to: writeTarget, mode: 0o600) }
        let expectFailure = ["file-sync-failure", "directory-sync-failure", "rename-failure", "parent-symlink"].contains(kind)
        try check(failed == expectFailure, "propagate atomic failure")
        if kind != "rename-failure" {
            let expected = ["file-sync-failure", "parent-symlink"].contains(kind) ? "pristine" : "complete replacement"
            try check(try pristine.readText(at: target) == expected, "correct bytes after failure boundary")
            let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
            try check(mode?.intValue == 0o600, "private mode")
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") }, "no temporary-file leak")
    }
}
'''

if "func replacePreservingAntiLeak(" not in (CORE / "SystemSupport.swift").read_text():
    print("protected_replacement_matrix supported=false")
    raise SystemExit(1)
atomic = ATOMIC_TESTS if "init(syncDescriptor:" in (CORE / "SystemSupport.swift").read_text() else 'test("atomic-sync-failure-propagation") { try check(false, "atomic sync seam missing") }'
scratch = Path(os.environ.get("TMPDIR", str(ROOT.parent / ".vex-tmp")))
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="protected-matrix-", dir=scratch) as raw:
    directory = Path(raw)
    (directory / "main.swift").write_text(HARNESS.replace("ATOMIC_TESTS", atomic))
    command = ["rtk", "proxy", "swiftc", "-swift-version", "5", *map(str, sorted(CORE.glob("*.swift"))),
               str(directory / "main.swift"), "-framework", "Security", "-framework", "SystemConfiguration",
               "-lbsm", "-o", str(directory / "probe")]
    result = subprocess.run(command, timeout=180)
    if result.returncode:
        raise SystemExit(result.returncode)
    env = dict(os.environ, TMPDIR=str(directory))
    raise SystemExit(subprocess.run(["rtk", "proxy", str(directory / "probe")], env=env, timeout=120).returncode)

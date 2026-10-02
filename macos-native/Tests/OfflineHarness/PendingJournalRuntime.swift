// Memory-only helper regression harness. Never launch the installed helper.

import Foundation
import Darwin

final class MemoryFiles: HelperFileSystem, @unchecked Sendable {
    var data: [String: String] = [:]
    var failDirectories = false, unreadableJournal = false
    var unknownJournalLookup = false
    var onDirectory: (() -> Void)?
    func createDirectory(at path: String) throws {
        let callback = onDirectory; onDirectory = nil; callback?()
        if failDirectories { throw HelperError.io("fixture directory failure") }
    }
    func fileExists(at path: String) -> Bool { data[path] != nil }
    func pathPresence(at path: String) -> HelperPathPresence {
        if unknownJournalLookup && path.hasSuffix("replacement-journal.state") { return .unknown }
        return data[path] == nil ? .absent : .present
    }
    func fileSize(at path: String) -> UInt64? { data[path].map { UInt64($0.utf8.count) } }
    func modificationDate(at path: String) -> Date? { nil }
    func readText(at path: String) throws -> String {
        if unreadableJournal && path.hasSuffix("replacement-journal.state") { throw HelperError.io("fixture unreadable journal") }
        guard let text = data[path] else { throw HelperError.io("fixture absent") }
        return text
    }
    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws { data[path] = text }
    func removeItem(at path: String) throws { data.removeValue(forKey: path) }
}
final class MemoryFirewall: PFFirewallControlling, @unchecked Sendable {
    var active = true, enables = 0, disables = 0, updates = 0
    func antileakIsActive() -> Bool { active }
    func enable(endpoint: String, interfaceName: String) throws { enables += 1; active = true }
    func disable() throws { disables += 1; active = false }
    func updateWhileArmed(endpoint: String, interfaceName: String) throws { updates += 1 }
}
final class MemoryTunnel: TunnelControlling, @unchecked Sendable {
    let firewall: MemoryFirewall
    var current: HelperSession?, up = 0, down = 0, repairs = 0
    var refreshes = 0
    var onRefresh: (() -> Void)?
    var cleanupMarker: String?
    init(_ firewall: MemoryFirewall, _ session: HelperSession?) { self.firewall = firewall; current = session }
    func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession {
        up += 1
        guard let current else { throw HelperError.commandFailed("fixture missing session") }
        return current
    }
    func bringDown(currentSession: HelperSession?) throws {
        down += 1; try firewall.disable(); current = nil
        if let cleanupMarker {
            Thread.sleep(forTimeInterval: 0.1)
            try "fixture cleanup completed\n".write(toFile: cleanupMarker, atomically: true, encoding: .utf8)
        }
    }
    func repair(currentSession: HelperSession?) throws -> HelperSession? { repairs += 1; return current }
    func refreshedSession(currentSession: HelperSession?) throws -> HelperSession? {
        refreshes += 1; onRefresh?(); return current
    }
    func hasManagedState() -> Bool { true }
}
struct DeadOwner: ProcessInspecting { func processIdentity(pid: Int32) -> String? { nil } }
final class MemoryOwner: ProcessInspecting, @unchecked Sendable {
    var identity: String? = "fixture-start"
    var onInspect: (() -> Void)?
    func processIdentity(pid: Int32) -> String? {
        let callback = onInspect; onInspect = nil; callback?(); return identity
    }
}
struct StopSleeper: AsyncSleeping {
    func sleep(for duration: Duration) async throws { throw CancellationError() }
}
struct FixturePeer: PeerAuthenticating {
    func authenticate(_ peer: PeerCredentials) -> Bool { peer.effectiveUID == geteuid() }
}
struct QuietLog: HelperLogging {
    func info(_ component: String, _ message: String) {}
    func warn(_ component: String, _ message: String) {}
    func error(_ component: String, _ message: String) {}
}
func paths() -> HelperPathsLayout {
    // These paths are exclusively dictionary keys; LocalFileSystem is never constructed.
    HelperPathsLayout(helperDirectory: "/f", socketPath: "/f/helper.sock",
        ownerSessionPath: "/f/owner.state", operationLockPath: "/f/operation.lock",
        antileakStatePath: "/f/antileak.state", legacyAntileakStatePath: "/f/antileak.active",
        antileakAnchorPath: "/f/anchor", sessionStatePath: "/f/session.state",
        interfacePath: "/f/utun.name", endpointPath: "/f/endpoint.txt",
        runtimeDirectory: "/f/runtime", amneziaRuntimeDirectory: "/f/amnezia",
        awgQuickPath: "/f/quick", configPathFile: "/f/config-path",
        defaultConfigPath: "/f/next.conf", activeConfigPath: "/f/active.conf",
        dnsStatePath: "/f/dns-baseline.state", awgPath: "/f/awg", pfConfigPath: "/f/pf.conf")
}
func config(_ endpoint: String) -> String {
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    let peer = Data(repeating: 2, count: 32).base64EncodedString()
    return "[Interface]\nPrivateKey = \(key)\nAddress = 10.23.4.2/32\nDNS = 1.1.1.1\nJc = 4\nJmin = 50\nJmax = 1000\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n[Peer]\nPublicKey = \(peer)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25\n"
}

struct RuntimeFixture {
    let p = paths(), files = MemoryFiles(), pf = MemoryFirewall(), owner = MemoryOwner()
    let store: HelperStateStore, tunnel: MemoryTunnel, runtime: HelperRuntime
    var journalPath: String { p.helperDirectory + "/replacement-journal.state" }
    init(phase: String) throws {
        store = HelperStateStore(fileSystem: files, paths: p)
        let session = HelperSession(interfaceName: "utun7", endpoint: "198.51.100.7:51820", ownerPID: 123,
            routeInterface: "utun7", socketExists: true, antiLeakArmed: true, latestHandshake: 1)
        try store.persistSession(session)
        let ownerRecord = OwnerSession(pid: 123, token: "fixture-intent", identity: "fixture-start")
        try store.persistOwnerSession(ownerRecord)
        let source = config("198.51.100.7:51820"), candidate = config("198.51.100.8:51820")
        files.data[p.activeConfigPath] = source
        files.data[p.dnsStatePath] = "fixture original DNS\n"
        if phase != "absent" && phase != "lookup-error" {
            var journal = ProtectedReplacementJournal(ownerPID: 123, sourceSession: session.payload,
                sourceConfig: source, sourceSHA256: ProtectedReplacementJournal.digest(source),
                candidateConfig: candidate, candidateSHA256: ProtectedReplacementJournal.digest(candidate),
                dnsBaseline: "fixture original DNS\n", ownerSession: ownerRecord.payload)
            journal.phase = ["corrupt", "unreadable"].contains(phase) ? "replacing" : phase
            files.data[p.helperDirectory + "/replacement-journal.state"] = phase == "corrupt" ? "invalid fixture journal" : try journal.encoded()
        }
        files.unreadableJournal = phase == "unreadable"
        files.unknownJournalLookup = phase == "lookup-error"
        tunnel = MemoryTunnel(pf, session)
        runtime = HelperRuntime(store: store, tunnelController: tunnel, firewallController: pf,
            processInspector: owner, sleeper: StopSleeper(), logger: QuietLog(),
            configuration: .init(handshakeStarveFailOpenTicks: 2))
    }
    var mutations: Int { tunnel.up + tunnel.down + tunnel.repairs + pf.enables + pf.disables + pf.updates }
}

@main struct Probe {
    static func main() async throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--serve" {
            let directory = CommandLine.arguments[2]
            let fixture = try RuntimeFixture(phase: CommandLine.arguments[3])
            fixture.tunnel.cleanupMarker = directory + "/cleanup.done"
            let server = UnixSocketServer(socketPath: directory + "/server.sock", logger: QuietLog(), authenticator: FixturePeer())
            try server.run(runtime: fixture.runtime)
            return
        }
        var failures = 0, cases = 0
        func check(_ passed: Bool, _ name: String) {
            cases += 1
            if !passed { failures += 1 }
            print("journal_regression name=\(name) pass=\(passed)")
        }
        let operations = ["recovery", "owner-tick", "owner-resume", "route-ticks", "handshake-ticks", "bootstrap-directory-failure"]
        for phase in ["prepared", "replacing", "rolling-back", "committed", "corrupt", "unreadable", "absent"] {
            for operation in operations {
                let p = paths(), files = MemoryFiles(), pf = MemoryFirewall()
                var session = HelperSession(interfaceName: "utun7", endpoint: "198.51.100.7:51820", ownerPID: 123,
                    routeInterface: "utun7", socketExists: true, antiLeakArmed: true, latestHandshake: 0)
                if operation == "route-ticks" { session.routeInterface = "en0" }
                let store = HelperStateStore(fileSystem: files, paths: p)
                try store.persistSession(session)
                let owner = OwnerSession(pid: 123, token: "fixture-intent", identity: "fixture-start")
                files.data[p.ownerSessionPath] = owner.payload
                let source = config("198.51.100.7:51820"), candidate = config("198.51.100.8:51820")
                files.data[p.activeConfigPath] = source
                files.data[p.dnsStatePath] = "fixture original DNS\n"
                let journalPath = p.helperDirectory + "/replacement-journal.state"
                if phase != "absent" {
                    var journal = ProtectedReplacementJournal(ownerPID: 123, sourceSession: session.payload,
                        sourceConfig: source, sourceSHA256: ProtectedReplacementJournal.digest(source),
                        candidateConfig: candidate, candidateSHA256: ProtectedReplacementJournal.digest(candidate),
                        dnsBaseline: "fixture original DNS\n", ownerSession: owner.payload)
                    journal.phase = ["corrupt", "unreadable"].contains(phase) ? "replacing" : phase
                    let encoded = try journal.encoded()
                    _ = try ProtectedReplacementJournal.decode(encoded)
                    files.data[journalPath] = phase == "corrupt" ? "invalid fixture journal" : encoded
                }
                files.unreadableJournal = phase == "unreadable"
                files.failDirectories = operation == "bootstrap-directory-failure"
                let tunnel = MemoryTunnel(pf, session)
                let runtime = HelperRuntime(store: store, tunnelController: tunnel, firewallController: pf,
                    processInspector: DeadOwner(), sleeper: StopSleeper(), logger: QuietLog(),
                    configuration: .init(handshakeStarveFailOpenTicks: 2))
                let before = files.data
                switch operation {
                case "recovery": await runtime.recoverStrandedAntiLeak()
                case "owner-tick": await runtime.runOwnerWatchdogTick()
                case "owner-resume": await runtime.resumeOwnerWatchdog()
                case "route-ticks", "handshake-ticks":
                    await runtime.runRouteWatchdogTick(); await runtime.runRouteWatchdogTick()
                default: do { try await runtime.bootstrap() } catch {}
                }
                let mutations = tunnel.up + tunnel.down + tunnel.repairs + pf.enables + pf.disables + pf.updates
                let preserved = files.data == before
                let passed = phase == "absent" ? mutations > 0 : mutations == 0 && preserved && pf.active
                cases += 1
                if !passed { failures += 1 }
                print("journal_runtime phase=\(phase) operation=\(operation) mutations=\(mutations) preserved=\(preserved) pass=\(passed)")
            }
        }

        let commands = ["up owner_pid=123", "up-no-antileak owner_pid=123", "down", "shutdown", "repair", "attach-owner owner_pid=123", "antileak-off"]
        for phase in ["prepared", "replacing", "rolling-back", "committed", "corrupt", "unreadable", "lookup-error", "absent"] {
            for command in commands {
                let fixture = try RuntimeFixture(phase: phase), before = fixture.files.data
                let response = await fixture.runtime.handle(commandLine: command, peerPID: 123)
                let passed: Bool
                if phase == "absent" {
                    passed = response.payload == "ok\n" && response.shouldExit == (command == "shutdown")
                        && (fixture.mutations > 0 || fixture.files.data != before)
                } else {
                    passed = response.payload == HelperError.replacementRecoveryPending.socketMessage && !response.shouldExit
                        && fixture.files.data == before && fixture.mutations == 0 && fixture.pf.active
                }
                check(passed, "rpc-\(phase)-\(command)")
            }
            let fixture = try RuntimeFixture(phase: phase), before = fixture.files.data
            let status = await fixture.runtime.handle(commandLine: "status", peerPID: 123)
            let diagnostics = await fixture.runtime.handle(commandLine: "diagnostics", peerPID: 123)
            let snapshot = await fixture.runtime.snapshotStatus()
            check(fixture.files.data == before && fixture.mutations == 0
                && snapshot.recoveryPending == (phase != "absent")
                && (phase == "absent"
                    ? status.payload.hasPrefix("state=connected ") && !status.payload.contains("recovery_pending=")
                    : status.payload.hasPrefix("state=error ") && status.payload.contains("recovery_pending=true")
                        && diagnostics.payload.contains("recovery_pending=true\n") && fixture.tunnel.refreshes == 0),
                "readonly-status-\(phase)")
        }

        for operation in commands + ["route-tick", "owner-tick", "owner-resume", "recovery", "bootstrap", "bootstrap-failure"] {
            let fixture = try RuntimeFixture(phase: "absent"), before = fixture.files.data
            fixture.owner.identity = nil
            fixture.files.onDirectory = { fixture.files.data[fixture.journalPath] = "fixture concurrent journal" }
            if operation == "bootstrap-failure" { fixture.files.failDirectories = true }
            switch operation {
            case "route-tick": await fixture.runtime.runRouteWatchdogTick()
            case "owner-tick": await fixture.runtime.runOwnerWatchdogTick()
            case "owner-resume": await fixture.runtime.resumeOwnerWatchdog()
            case "recovery": await fixture.runtime.recoverStrandedAntiLeak()
            case "bootstrap", "bootstrap-failure": do { try await fixture.runtime.bootstrap() } catch {}
            default: _ = await fixture.runtime.handle(commandLine: operation, peerPID: 123)
            }
            var expected = before; expected[fixture.journalPath] = "fixture concurrent journal"
            check(fixture.files.data == expected && fixture.mutations == 0 && fixture.pf.active, "lease-recheck-\(operation)")
        }

        for operation in ["recovery", "owner-tick", "owner-resume", "route-tick", "bootstrap-failure"] {
            let fixture = try RuntimeFixture(phase: "lookup-error"), before = fixture.files.data
            fixture.owner.identity = nil
            switch operation {
            case "recovery": await fixture.runtime.recoverStrandedAntiLeak()
            case "owner-tick": await fixture.runtime.runOwnerWatchdogTick()
            case "owner-resume": await fixture.runtime.resumeOwnerWatchdog()
            case "route-tick": await fixture.runtime.runRouteWatchdogTick()
            default:
                fixture.files.failDirectories = true
                do { try await fixture.runtime.bootstrap() } catch {}
            }
            check(fixture.files.data == before && fixture.mutations == 0 && fixture.pf.active, "unknown-lookup-\(operation)")
        }

        do {
            let fixture = try RuntimeFixture(phase: "absent")
            var competitorRejected = false
            fixture.tunnel.onRefresh = {
                do { try fixture.store.withOperationLock(staleAfter: 120) { fixture.files.data[fixture.journalPath] = "unexpected competitor" } }
                catch HelperError.operationInProgress { competitorRejected = true }
                catch {}
            }
            await fixture.runtime.runRouteWatchdogTick()
            check(competitorRejected && fixture.files.data[fixture.journalPath] == nil && fixture.mutations == 0, "health-refresh-holds-whole-operation-lease")
        }
        do {
            let fixture = try RuntimeFixture(phase: "absent")
            fixture.owner.identity = nil
            let replacementOwner = OwnerSession(pid: 124, token: "next-intent", identity: "next-start").payload
            fixture.owner.onInspect = { fixture.files.data[fixture.p.ownerSessionPath] = replacementOwner }
            await fixture.runtime.runOwnerWatchdogTick()
            check(fixture.files.data[fixture.p.ownerSessionPath] == replacementOwner && fixture.mutations == 0, "owner-cleanup-revalidates-identity")
        }
        do {
            let fixture = try RuntimeFixture(phase: "absent")
            _ = await fixture.runtime.snapshotStatus()
            fixture.files.data[fixture.journalPath] = "fixture pending"
            let refreshes = fixture.tunnel.refreshes
            let pending = await fixture.runtime.snapshotStatus()
            fixture.files.data.removeValue(forKey: fixture.journalPath)
            let resumed = await fixture.runtime.snapshotStatus()
            check(pending.state == "error" && pending.recoveryPending && resumed.state == "connected"
                && !resumed.recoveryPending && fixture.tunnel.refreshes == refreshes + 1, "status-cache-invalidated-and-ordinary-progress-resumes")
        }

        // Filesystem-only fixtures exercise real Darwin lookup semantics, not
        // tunnel/PF/process ports. All files live inside the caller's temp root.
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("presence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = LocalFileSystem(), leaf = directory.appendingPathComponent("journal").path
        check(local.pathPresence(at: leaf) == .absent, "local-confirmed-absence")
        try Data().write(to: URL(fileURLWithPath: leaf))
        check(local.pathPresence(at: leaf) == .present, "local-empty-journal")
        check(local.pathPresence(at: leaf + "/child") == .unknown, "local-not-directory-is-unknown")
        _ = chmod(leaf, 0)
        check(local.pathPresence(at: leaf) == .present, "local-unreadable-journal-is-present")
        _ = chmod(leaf, 0o600)
        let link = directory.appendingPathComponent("dangling").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory.appendingPathComponent("missing-target").path)
        check(local.pathPresence(at: link) == .present, "local-dangling-journal-is-present")
        check(local.pathPresence(at: link + "/journal") == .unknown, "local-dangling-parent-is-unknown")
        check(local.pathPresence(at: directory.appendingPathComponent("missing/parent/journal").path) == .absent, "local-missing-ancestors")
        check(local.pathPresence(at: directory.path) == .present, "local-directory-is-not-absent")
        check(local.pathPresence(at: directory.path + "/" + String(repeating: "x", count: 400)) == .unknown, "local-lookup-error-is-unknown")
        if geteuid() != 0 {
            let denied = directory.appendingPathComponent("denied").path
            try FileManager.default.createDirectory(atPath: denied, withIntermediateDirectories: true)
            _ = chmod(denied, 0)
            let result = local.pathPresence(at: denied + "/journal")
            _ = chmod(denied, 0o700)
            check(result == .unknown, "local-inaccessible-parent-is-unknown")
        }
        print("journal_runtime_matrix cases=\(cases) failures=\(failures) live_network_commands=0")
        exit(failures == 0 ? 0 : 1)
    }
}

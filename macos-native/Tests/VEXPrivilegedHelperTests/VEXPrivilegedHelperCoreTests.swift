import Foundation
import XCTest
@testable import VEXHelperCore

final class VEXPrivilegedHelperCoreTests: XCTestCase {
    func testRecognizedCommandsMatchRustProtocolSurface() throws {
        XCTAssertEqual(try HelperCommand.parse("status"), .status)
        XCTAssertEqual(try HelperCommand.parse("down"), .down)
        XCTAssertEqual(try HelperCommand.parse("shutdown"), .shutdown)
        XCTAssertEqual(try HelperCommand.parse("repair"), .repair)
        XCTAssertEqual(try HelperCommand.parse("antileak-off"), .antiLeakOff)
        XCTAssertEqual(try HelperCommand.parse("attach-owner owner_pid=4321"), .attachOwner(ownerPID: 4321))
        XCTAssertEqual(try HelperCommand.parse("up owner_pid=1234"), .up(armAntiLeak: true, ownerPID: 1234))
        XCTAssertEqual(try HelperCommand.parse("up-no-antileak owner-pid=5678"), .up(armAntiLeak: false, ownerPID: 5678))
    }

    func testUnknownAndOversizedCommandsAreRejected() throws {
        XCTAssertThrowsError(try HelperCommand.parse("reconnect"))
        let oversized = Array(repeating: UInt8(ascii: "a"), count: 513)
        XCTAssertThrowsError(try HelperCommandFrame.decode(oversized, maxBytes: 512))
    }

    func testCommandFramesRejectTruncationInvalidUTF8AndAmbiguousOwnerMetadata() throws {
        XCTAssertEqual(
            try HelperCommandFrame.decode(Array("status\n".utf8), maxBytes: 512),
            "status"
        )
        XCTAssertThrowsError(
            try HelperCommandFrame.decode(Array("status".utf8), maxBytes: 512)
        )
        XCTAssertThrowsError(
            try HelperCommandFrame.decode([0xFF, 0x0A], maxBytes: 512)
        )
        XCTAssertThrowsError(
            try HelperCommand.parse("up owner_pid=1234 owner-pid=5678")
        )
    }

    func testBootstrapFlushesLiveAntiLeakBeforeFailingWhenStateDirectoriesCannotBeCreated() async {
        let fileSystem = InMemoryFileSystem(failDirectories: ["/helper"])
        let firewall = TrackingFirewall(active: true)
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime"
        )
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: paths),
            tunnelController: RepairingTunnelController(refreshed: nil),
            firewallController: firewall,
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        do {
            try await runtime.bootstrap()
            XCTFail("bootstrap must fail when its root-owned state directory is unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected directory failure"))
            XCTAssertEqual(firewall.disableCallCount, 1)
        }
    }

    func testOperationLockReflectsInProgressAndPersistsSessionAtomically() throws {
        let fileSystem = InMemoryFileSystem()
        let dateProvider = MutableDateProvider(now: Date(timeIntervalSince1970: 1_000))
        let store = HelperStateStore(
            fileSystem: fileSystem,
            paths: HelperPathsLayout(helperDirectory: "/helper", socketPath: "/tmp/helper.sock", ownerSessionPath: "/helper/owner.state", operationLockPath: "/helper/operation.lock", antileakStatePath: "/helper/antileak.state", legacyAntileakStatePath: "/helper/antileak.active", antileakAnchorPath: "/helper/anchor", sessionStatePath: "/helper/session.state", interfacePath: "/helper/utun.name", endpointPath: "/helper/endpoint.txt", runtimeDirectory: "/runtime"),
            dateProvider: dateProvider
        )

        try store.withOperationLock(staleAfter: 120) {
            XCTAssertTrue(store.operationInProgress(staleAfter: 120))
            try store.persistSession(HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820", socketExists: true, antiLeakArmed: true))
            let loaded = store.loadSession()
            XCTAssertEqual(loaded?.interfaceName, "utun9")
            XCTAssertEqual(loaded?.endpoint, "1.1.1.1:51820")
        }
        XCTAssertFalse(store.operationInProgress(staleAfter: 120))
    }

    func testPFDisableKeepsRecoveryStateWhenStatusQueryFails() throws {
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-F", "all"]): .init(status: 1),
            CommandSpec(program: "/sbin/pfctl", arguments: ["-s", "info"]): .init(status: 1, stderr: "pf unavailable")
        ])
        let fileSystem = InMemoryFileSystem(files: ["/helper/antileak.state": "status=active\n", "/helper/anchor": "block drop out all\n"])
        let firewall = SystemPFFirewallController(
            runner: runner,
            fileSystem: fileSystem,
            paths: HelperPathsLayout(helperDirectory: "/helper", socketPath: "/tmp/helper.sock", ownerSessionPath: "/helper/owner.state", operationLockPath: "/helper/operation.lock", antileakStatePath: "/helper/antileak.state", legacyAntileakStatePath: "/helper/antileak.active", antileakAnchorPath: "/helper/anchor", sessionStatePath: "/helper/session.state", interfacePath: "/helper/utun.name", endpointPath: "/helper/endpoint.txt", runtimeDirectory: "/runtime")
        )

        XCTAssertThrowsError(try firewall.disable())
        XCTAssertTrue(fileSystem.fileExists(at: "/helper/antileak.state"))
    }

    func testOwnerWatchdogTearsDownSessionWhenIdentityChanges() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/session.state": HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820", ownerPID: 42, socketExists: true, antiLeakArmed: true).payload,
            "/helper/owner.state": OwnerSession(pid: 42, token: "42-token", identity: "old").payload,
            "/helper/anchor": "block drop out all\n",
            "/helper/antileak.state": "status=active\n",
            "/helper/config-path": "/helper/vex.conf\n",
            "/helper/vex.conf": "[Peer]\nEndpoint = 1.1.1.1:51820\n",
            "/helper/dns-baseline.state": "\n"
        ])
        let paths = HelperPathsLayout(helperDirectory: "/helper", socketPath: "/tmp/helper.sock", ownerSessionPath: "/helper/owner.state", operationLockPath: "/helper/operation.lock", antileakStatePath: "/helper/antileak.state", legacyAntileakStatePath: "/helper/antileak.active", antileakAnchorPath: "/helper/anchor", sessionStatePath: "/helper/session.state", interfacePath: "/helper/utun.name", endpointPath: "/helper/endpoint.txt", runtimeDirectory: "/runtime", configPathFile: "/helper/config-path", defaultConfigPath: "/helper/vex.conf", dnsStatePath: "/helper/dns-baseline.state")
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-F", "all"]): .init(status: 0),
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-sr"]): .init(status: 0, stdout: "   "),
            CommandSpec(program: "/sbin/ifconfig", arguments: ["utun9", "down"]): .init(status: 0)
        ])
        let firewall = SystemPFFirewallController(runner: runner, fileSystem: fileSystem, paths: paths)
        let tunnel = SystemTunnelController(fileSystem: fileSystem, paths: paths, runner: runner, firewall: firewall)
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: paths),
            tunnelController: tunnel,
            firewallController: firewall,
            processInspector: StaticProcessInspector(identities: [42: "new"]),
            sleeper: ManualSleeper()
        )

        await runtime.runOwnerWatchdogTick()

        let snapshot = await runtime.snapshotStatus()
        XCTAssertEqual(snapshot.state, "disconnected")
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/owner.state"))
    }

    func testRouteWatchdogTriggersRepairForRouteDrift() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/session.state": HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820", ownerPID: 42, routeInterface: "en0", socketExists: true, antiLeakArmed: false).payload
        ])
        let tunnel = RepairingTunnelController(refreshed: HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820", ownerPID: 42, routeInterface: "en0", socketExists: true, antiLeakArmed: false))
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: HelperPathsLayout(helperDirectory: "/helper", socketPath: "/tmp/helper.sock", ownerSessionPath: "/helper/owner.state", operationLockPath: "/helper/operation.lock", antileakStatePath: "/helper/antileak.state", legacyAntileakStatePath: "/helper/antileak.active", antileakAnchorPath: "/helper/anchor", sessionStatePath: "/helper/session.state", interfacePath: "/helper/utun.name", endpointPath: "/helper/endpoint.txt", runtimeDirectory: "/runtime")),
            tunnelController: tunnel,
            firewallController: PassiveFirewall(),
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        await runtime.runRouteWatchdogTick()

        XCTAssertEqual(tunnel.repairCallCount, 1)
    }

    func testSwiftTunnelUsesQuickScriptAndRollsBackAfterPFEnableFailure() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            amneziaRuntimeDirectory: "/amnezia",
            awgQuickPath: "/helper/awg-quick.sh",
            configPathFile: "/helper/config-path",
            defaultConfigPath: "/helper/vex.conf",
            activeConfigPath: "/helper/active.conf",
            dnsStatePath: "/helper/dns-baseline.state"
        )
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/config-path": "/helper/vex.conf\n",
            "/helper/vex.conf": "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nEndpoint = 1.1.1.1:51820\nAllowedIPs = 0.0.0.0/0\n",
            "/amnezia/active.name": "utun9\n",
            "/helper/dns-baseline.state": "\n",
            "/runtime/utun9.sock": ""
        ])
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["up", "/helper/vex.conf"]): .init(status: 0),
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["down", "/helper/vex.conf"]): .init(status: 0),
            CommandSpec(program: "/sbin/route", arguments: ["-n", "get", "1.1.1.1"]): .init(status: 0, stdout: "interface: utun9\n"),
            CommandSpec(program: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet6"]): .init(status: 0)
        ])
        let firewall = FailingEnableFirewall()
        let tunnel = SystemTunnelController(fileSystem: fileSystem, paths: paths, runner: runner, firewall: firewall)

        XCTAssertThrowsError(try tunnel.bringUp(currentSession: nil, armAntiLeak: true, ownerPID: 42))
        XCTAssertEqual(
            runner.calls.filter { $0.program == "/helper/awg-quick.sh" }.map(\.arguments.first),
            ["up", "down"]
        )
    }

    func testSwiftTunnelRejectsLifecycleHooksBeforeExecutingRootQuickScript() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            awgQuickPath: "/helper/awg-quick.sh",
            configPathFile: "/helper/config-path",
            defaultConfigPath: "/helper/vex.conf",
            activeConfigPath: "/helper/active.conf"
        )
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/config-path": "/user/vex.conf\n",
            "/user/vex.conf": "[Interface]\nPrivateKey = key\nPreUp = touch /root/pwned\n[Peer]\nEndpoint = 1.1.1.1:51820\n"
        ])
        let runner = RecordingCommandRunner([:])
        let tunnel = SystemTunnelController(
            fileSystem: fileSystem,
            paths: paths,
            runner: runner,
            firewall: PassiveFirewall()
        )

        XCTAssertThrowsError(try tunnel.bringUp(currentSession: nil, armAntiLeak: false, ownerPID: 42))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/active.conf"))
    }

    func testBringDownUsesRootOwnedActiveConfigWhenUserConfigDisappears() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            awgQuickPath: "/helper/awg-quick.sh",
            configPathFile: "/helper/config-path",
            defaultConfigPath: "/user/vex.conf",
            activeConfigPath: "/helper/active.conf",
            dnsStatePath: "/helper/dns-baseline.state"
        )
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/active.conf": "[Interface]\nPrivateKey = key\n[Peer]\nEndpoint = 1.1.1.1:51820\n",
            "/helper/dns-baseline.state": "\n"
        ])
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["down", "/helper/active.conf"]): .init(status: 0)
        ])
        let tunnel = SystemTunnelController(
            fileSystem: fileSystem,
            paths: paths,
            runner: runner,
            firewall: PassiveFirewall()
        )

        try tunnel.bringDown(currentSession: HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820"))

        XCTAssertEqual(runner.calls.first?.arguments, ["down", "/helper/active.conf"])
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/active.conf"))
    }

    func testContinuousSupervisorFailsOpenAfterRepeatedBrokenTunnelHealth() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/session.state": HelperSession(
                interfaceName: "utun9",
                endpoint: "1.1.1.1:51820",
                ownerPID: 42,
                routeInterface: "en0",
                socketExists: false,
                antiLeakArmed: true
            ).payload
        ])
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime"
        )
        let tunnel = AlwaysBrokenTunnelController()
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: paths),
            tunnelController: tunnel,
            firewallController: ActiveFirewall(),
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        await runtime.runRouteWatchdogTick()
        await runtime.runRouteWatchdogTick()

        XCTAssertEqual(tunnel.bringDownCallCount, 1)
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/session.state"))
    }

    func testBootstrapRecoveryTearsDownPersistedTunnelEvenWithoutAntiLeak() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/session.state": HelperSession(
                interfaceName: "utun9",
                endpoint: "1.1.1.1:51820",
                ownerPID: 42,
                routeInterface: "utun9",
                socketExists: true,
                antiLeakArmed: false
            ).payload
        ])
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime"
        )
        let tunnel = AlwaysBrokenTunnelController()
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: paths),
            tunnelController: tunnel,
            firewallController: PassiveFirewall(),
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        await runtime.recoverStrandedAntiLeak()

        XCTAssertEqual(tunnel.bringDownCallCount, 1)
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/session.state"))
    }

    func testBootstrapRecoveryUsesActiveConfigFromCrashBeforeSessionPersist() async throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            awgQuickPath: "/helper/awg-quick.sh",
            activeConfigPath: "/helper/active.conf",
            dnsStatePath: "/helper/dns-baseline.state"
        )
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/active.conf": "[Interface]\nPrivateKey = key\n[Peer]\nEndpoint = 1.1.1.1:51820\n",
            "/helper/dns-baseline.state": "\n"
        ])
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["down", "/helper/active.conf"]): .init(status: 0)
        ])
        let firewall = PassiveFirewall()
        let tunnel = SystemTunnelController(fileSystem: fileSystem, paths: paths, runner: runner, firewall: firewall)
        let runtime = HelperRuntime(
            store: HelperStateStore(fileSystem: fileSystem, paths: paths),
            tunnelController: tunnel,
            firewallController: firewall,
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        await runtime.recoverStrandedAntiLeak()

        XCTAssertEqual(runner.calls.first?.arguments, ["down", "/helper/active.conf"])
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/active.conf"))
    }

    func testPartialUpFailurePreservesRecoveryArtifactsUntilTunnelCleanupSucceeds() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            awgQuickPath: "/helper/awg-quick.sh",
            configPathFile: "/helper/config-path",
            defaultConfigPath: "/user/vex.conf",
            activeConfigPath: "/helper/active.conf",
            dnsStatePath: "/helper/dns-baseline.state"
        )
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/config-path": "/user/vex.conf\n",
            "/user/vex.conf": "[Interface]\nPrivateKey = key\n[Peer]\nEndpoint = 1.1.1.1:51820\n"
        ])
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["up", "/helper/active.conf"]): .init(status: 124),
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["down", "/helper/active.conf"]): .init(status: 1)
        ])
        let tunnel = SystemTunnelController(
            fileSystem: fileSystem,
            paths: paths,
            runner: runner,
            firewall: PassiveFirewall()
        )

        XCTAssertThrowsError(try tunnel.bringUp(currentSession: nil, armAntiLeak: false, ownerPID: 42))
        XCTAssertTrue(fileSystem.fileExists(at: "/helper/active.conf"))
        XCTAssertTrue(fileSystem.fileExists(at: "/helper/dns-baseline.state"))
    }

    func testDisconnectRestoresPersistedDNSBaselineBeforeClearingRecoveryState() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime",
            awgQuickPath: "/helper/awg-quick.sh",
            activeConfigPath: "/helper/active.conf",
            dnsStatePath: "/helper/dns-baseline.state"
        )
        let encode: (String) -> String = { Data($0.utf8).base64EncodedString() }
        let baseline = [encode("Wi-Fi"), encode("9.9.9.9\n"), encode("corp.example\n")].joined(separator: "|") + "\n"
        let fileSystem = InMemoryFileSystem(files: [
            "/helper/active.conf": "[Interface]\nPrivateKey = key\n",
            "/helper/dns-baseline.state": baseline
        ])
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/helper/awg-quick.sh", arguments: ["down", "/helper/active.conf"]): .init(status: 0)
        ])
        let tunnel = SystemTunnelController(
            fileSystem: fileSystem,
            paths: paths,
            runner: runner,
            firewall: PassiveFirewall()
        )

        try tunnel.bringDown(currentSession: HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820"))

        XCTAssertTrue(runner.calls.contains(CommandSpec(
            program: "/usr/sbin/networksetup",
            arguments: ["-setdnsservers", "Wi-Fi", "9.9.9.9"],
            timeout: 5
        )))
        XCTAssertTrue(runner.calls.contains(CommandSpec(
            program: "/usr/sbin/networksetup",
            arguments: ["-setsearchdomains", "Wi-Fi", "corp.example"],
            timeout: 5
        )))
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/active.conf"))
        XCTAssertFalse(fileSystem.fileExists(at: "/helper/dns-baseline.state"))
    }

    func testPFDisableFlushesLiveRulesButKeepsRecoveryMarkerWhenDiskClearFails() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime"
        )
        let fileSystem = InMemoryFileSystem(
            files: ["/helper/antileak.state": "status=active\n", "/helper/anchor": "block drop out all\n"],
            failWrites: ["/helper/anchor"]
        )
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-F", "all"]): .init(status: 0),
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-sr"]): .init(status: 0, stdout: "")
        ])
        let firewall = SystemPFFirewallController(runner: runner, fileSystem: fileSystem, paths: paths)

        XCTAssertThrowsError(try firewall.disable())
        XCTAssertTrue(runner.calls.contains(CommandSpec(
            program: "/sbin/pfctl",
            arguments: ["-a", "com.vexguard.antileak", "-F", "all"]
        )))
        XCTAssertTrue(fileSystem.fileExists(at: "/helper/antileak.state"))
    }

    func testBringDownReportsPFPersistenceFailureEvenWithoutTunnelArtifacts() throws {
        let paths = HelperPathsLayout(
            helperDirectory: "/helper",
            socketPath: "/tmp/helper.sock",
            ownerSessionPath: "/helper/owner.state",
            operationLockPath: "/helper/operation.lock",
            antileakStatePath: "/helper/antileak.state",
            legacyAntileakStatePath: "/helper/antileak.active",
            antileakAnchorPath: "/helper/anchor",
            sessionStatePath: "/helper/session.state",
            interfacePath: "/helper/utun.name",
            endpointPath: "/helper/endpoint.txt",
            runtimeDirectory: "/runtime"
        )
        let fileSystem = InMemoryFileSystem(
            files: ["/helper/antileak.state": "status=active\n", "/helper/anchor": "block drop out all\n"],
            failWrites: ["/helper/anchor"]
        )
        let runner = RecordingCommandRunner([
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-F", "all"]): .init(status: 0),
            CommandSpec(program: "/sbin/pfctl", arguments: ["-a", "com.vexguard.antileak", "-sr"]): .init(status: 0, stdout: "")
        ])
        let firewall = SystemPFFirewallController(runner: runner, fileSystem: fileSystem, paths: paths)
        let tunnel = SystemTunnelController(
            fileSystem: fileSystem,
            paths: paths,
            runner: runner,
            firewall: firewall
        )

        XCTAssertThrowsError(try tunnel.bringDown(currentSession: HelperSession(
            interfaceName: "utun9",
            endpoint: "1.1.1.1:51820",
            antiLeakArmed: true
        )))
        XCTAssertTrue(fileSystem.fileExists(at: "/helper/antileak.state"))
    }

    func testZeroHandshakeUsesStartupGraceInsteadOfImmediateTeardown() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let session = HelperSession(
            interfaceName: "utun9",
            endpoint: "1.1.1.1:51820",
            ownerPID: 42,
            routeInterface: "utun9",
            socketExists: true,
            antiLeakArmed: false,
            latestHandshake: 0,
            startedAt: 9_990,
            dnsHealthy: true
        )
        let fileSystem = InMemoryFileSystem(files: ["/helper/session.state": session.payload])
        let tunnel = RepairingTunnelController(refreshed: session)
        let runtime = HelperRuntime(
            store: HelperStateStore(
                fileSystem: fileSystem,
                paths: HelperPathsLayout(
                    helperDirectory: "/helper",
                    socketPath: "/tmp/helper.sock",
                    ownerSessionPath: "/helper/owner.state",
                    operationLockPath: "/helper/operation.lock",
                    antileakStatePath: "/helper/antileak.state",
                    legacyAntileakStatePath: "/helper/antileak.active",
                    antileakAnchorPath: "/helper/anchor",
                    sessionStatePath: "/helper/session.state",
                    interfacePath: "/helper/utun.name",
                    endpointPath: "/helper/endpoint.txt",
                    runtimeDirectory: "/runtime"
                )
            ),
            tunnelController: tunnel,
            firewallController: PassiveFirewall(),
            processInspector: StaticProcessInspector(identities: [:]),
            dateProvider: MutableDateProvider(now: now),
            sleeper: ManualSleeper()
        )

        await runtime.runRouteWatchdogTick()

        XCTAssertEqual(tunnel.repairCallCount, 0)
    }

    func testIdleStructurallyHealthyTunnelIsNotRepairedOrTornDownForStaleHandshake() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let session = HelperSession(
            interfaceName: "utun9",
            endpoint: "1.1.1.1:51820",
            ownerPID: 42,
            routeInterface: "utun9",
            socketExists: true,
            antiLeakArmed: true,
            latestHandshake: 9_000,
            startedAt: 8_000,
            dnsHealthy: true
        )
        let fileSystem = InMemoryFileSystem(files: ["/helper/session.state": session.payload])
        let tunnel = RepairingTunnelController(refreshed: session)
        let runtime = HelperRuntime(
            store: HelperStateStore(
                fileSystem: fileSystem,
                paths: HelperPathsLayout(
                    helperDirectory: "/helper",
                    socketPath: "/tmp/helper.sock",
                    ownerSessionPath: "/helper/owner.state",
                    operationLockPath: "/helper/operation.lock",
                    antileakStatePath: "/helper/antileak.state",
                    legacyAntileakStatePath: "/helper/antileak.active",
                    antileakAnchorPath: "/helper/anchor",
                    sessionStatePath: "/helper/session.state",
                    interfacePath: "/helper/utun.name",
                    endpointPath: "/helper/endpoint.txt",
                    runtimeDirectory: "/runtime"
                )
            ),
            tunnelController: tunnel,
            firewallController: PassiveFirewall(),
            processInspector: StaticProcessInspector(identities: [42: "same-owner"]),
            dateProvider: MutableDateProvider(now: now),
            sleeper: ManualSleeper()
        )

        await runtime.runRouteWatchdogTick()
        await runtime.runRouteWatchdogTick()

        XCTAssertEqual(tunnel.repairCallCount, 0)
        XCTAssertEqual(tunnel.bringDownCallCount, 0)
    }

    func testDNSHealthRequiresExpectedServersOnEffectiveDefaultResolver() {
        let unrelatedResolver = """
        resolver #1
          nameserver[0] : 192.168.1.1
          if_index : 4 (en0)
          flags    : Request A records
        resolver #2
          nameserver[0] : 10.64.1.1
          domain   : unrelated.example
          flags    : Supplemental, Request A records
        """
        let effectiveServiceResolver = """
        resolver #1
          nameserver[0] : 10.64.1.1
          if_index : 4 (en0)
          flags    : Request A records
        """

        XCTAssertFalse(SystemTunnelController.dnsOutput(
            unrelatedResolver,
            contains: ["10.64.1.1"],
            forInterface: "utun9"
        ))
        XCTAssertTrue(SystemTunnelController.dnsOutput(
            effectiveServiceResolver,
            contains: ["10.64.1.1"],
            forInterface: "utun9"
        ))
        XCTAssertEqual(
            SystemTunnelController.configuredDNSServers(
                "[Interface]\nDNS = 10.64.1.1, 2001:4860:4860::8888, corp.example\n"
            ),
            ["10.64.1.1", "2001:4860:4860::8888"]
        )
    }

    func testIPv6FullTunnelRequiresBothRouteHalvesOnSameInterface() {
        XCTAssertEqual(
            SystemTunnelController.consistentIPv6FullTunnelInterface(["utun9", "utun9"]),
            "utun9"
        )
        XCTAssertNil(
            SystemTunnelController.consistentIPv6FullTunnelInterface(["utun9", nil])
        )
        XCTAssertNil(
            SystemTunnelController.consistentIPv6FullTunnelInterface(["utun9", "en0"])
        )
    }

    func testHelperStatusDoesNotReportConnectedWhenExpectedIPv6RouteIsBroken() {
        let status = HelperStatusSnapshot(
            operationInProgress: false,
            interfaceName: "utun9",
            endpoint: "1.1.1.1:51820",
            socketExists: true,
            routeOK: true,
            routeInterface: "utun9",
            ipv6RouteExpected: true,
            ipv6RouteOK: false,
            ipv6RouteInterface: "",
            rxBytes: 0,
            txBytes: 0,
            latestHandshake: 0,
            leakProtection: "off"
        )

        XCTAssertEqual(status.state, "error")
    }

    func testExpectedIPv6DefaultRouteMustExistOnTunnelInterface() async throws {
        let session = HelperSession(
            interfaceName: "utun9",
            endpoint: "1.1.1.1:51820",
            routeInterface: "utun9",
            ipv6RouteInterface: nil,
            socketExists: true,
            ipv6RouteExpected: true,
            dnsHealthy: true
        )
        let fileSystem = InMemoryFileSystem(files: ["/helper/session.state": session.payload])
        let tunnel = RepairingTunnelController(refreshed: session)
        let runtime = HelperRuntime(
            store: HelperStateStore(
                fileSystem: fileSystem,
                paths: HelperPathsLayout(
                    helperDirectory: "/helper",
                    socketPath: "/tmp/helper.sock",
                    ownerSessionPath: "/helper/owner.state",
                    operationLockPath: "/helper/operation.lock",
                    antileakStatePath: "/helper/antileak.state",
                    legacyAntileakStatePath: "/helper/antileak.active",
                    antileakAnchorPath: "/helper/anchor",
                    sessionStatePath: "/helper/session.state",
                    interfacePath: "/helper/utun.name",
                    endpointPath: "/helper/endpoint.txt",
                    runtimeDirectory: "/runtime"
                )
            ),
            tunnelController: tunnel,
            firewallController: PassiveFirewall(),
            processInspector: StaticProcessInspector(identities: [:]),
            sleeper: ManualSleeper()
        )

        let snapshot = await runtime.snapshotStatus()
        await runtime.runRouteWatchdogTick()

        XCTAssertFalse(snapshot.ipv6RouteOK)
        XCTAssertEqual(tunnel.repairCallCount, 1)
    }

    func testSystemProcessIdentityUsesSubsecondStartTimeToDetectPIDReuse() throws {
        let identity = try XCTUnwrap(
            SystemProcessInspector().processIdentity(pid: getpid())
        )

        XCTAssertTrue(identity.contains("start_usec="))
        XCTAssertTrue(identity.contains("uid=\(geteuid())"))
        XCTAssertNil(SystemProcessInspector().processIdentity(pid: Int32.max))
    }

    func testSocketWriterDrainsEntirePayloadAcrossPartialWrites() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }

        var sendBuffer: Int32 = 1_024
        XCTAssertEqual(
            setsockopt(
                sockets[0],
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )

        let payload = [UInt8](repeating: 0x61, count: 512 * 1_024)
        let reader = Task.detached { () -> Int in
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while total < payload.count {
                let count = Darwin.read(sockets[1], &buffer, buffer.count)
                if count > 0 {
                    total += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return total
        }

        try HelperSocketIO.writeAll(payload, to: sockets[0])
        let receivedCount = await reader.value
        XCTAssertEqual(receivedCount, payload.count)
    }
}

private final class InMemoryFileSystem: HelperFileSystem, @unchecked Sendable {
    private var directories = Set<String>()
    private var files: [String: String]
    private var modificationDates: [String: Date]
    private let failWrites: Set<String>
    private let failDirectories: Set<String>
    private let lock = NSLock()

    init(
        files: [String: String] = [:],
        failWrites: Set<String> = [],
        failDirectories: Set<String> = []
    ) {
        self.files = files
        self.modificationDates = files.reduce(into: [:]) { result, entry in result[entry.key] = Date() }
        self.failWrites = failWrites
        self.failDirectories = failDirectories
    }

    func createDirectory(at path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failDirectories.contains(path) {
            throw HelperError.io("injected directory failure for \(path)")
        }
        directories.insert(path)
    }

    func fileExists(at path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[path] != nil
    }

    func fileSize(at path: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return files[path].map { UInt64($0.utf8.count) }
    }

    func modificationDate(at path: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return modificationDates[path]
    }

    func readText(at path: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = files[path] { return value }
        throw HelperError.io("missing \(path)")
    }

    func writeTextAtomically(_ text: String, to path: String, mode: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites.contains(path) {
            throw HelperError.io("injected write failure for \(path)")
        }
        files[path] = text
        modificationDates[path] = Date()
    }

    func removeItem(at path: String) throws {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: path)
        modificationDates.removeValue(forKey: path)
    }
}

private struct MutableDateProvider: DateProviding {
    var now: Date
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let results: [CommandSpec: CommandResult]
    private let lock = NSLock()
    private(set) var calls: [CommandSpec] = []

    init(_ results: [CommandSpec: CommandResult]) {
        self.results = results
    }

    func run(_ spec: CommandSpec) throws -> CommandResult {
        lock.withLock { calls.append(spec) }
        return results[spec] ?? .init(status: 0)
    }
}

private struct StaticProcessInspector: ProcessInspecting {
    let identities: [Int32: String]

    func processIdentity(pid: Int32) -> String? {
        identities[pid]
    }
}

private struct ManualSleeper: AsyncSleeping {
    func sleep(for duration: Duration) async throws {}
}

private final class RepairingTunnelController: TunnelControlling, @unchecked Sendable {
    var refreshed: HelperSession?
    private(set) var repairCallCount = 0
    private(set) var bringDownCallCount = 0

    init(refreshed: HelperSession?) {
        self.refreshed = refreshed
    }

    func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession {
        refreshed ?? currentSession ?? HelperSession(interfaceName: "", endpoint: "")
    }

    func bringDown(currentSession: HelperSession?) throws {
        bringDownCallCount += 1
    }

    func repair(currentSession: HelperSession?) throws -> HelperSession? {
        repairCallCount += 1
        if var refreshed {
            refreshed.routeInterface = refreshed.interfaceName
            self.refreshed = refreshed
            return refreshed
        }
        return nil
    }

    func refreshedSession(currentSession: HelperSession?) throws -> HelperSession? {
        refreshed ?? currentSession
    }
}

private struct PassiveFirewall: PFFirewallControlling {
    func antileakIsActive() -> Bool { false }
    func enable(endpoint: String, interfaceName: String) throws {}
    func disable() throws {}
}

private final class TrackingFirewall: PFFirewallControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let active: Bool
    private var _disableCallCount = 0

    init(active: Bool) {
        self.active = active
    }

    var disableCallCount: Int {
        lock.withLock { _disableCallCount }
    }

    func antileakIsActive() -> Bool { active }
    func enable(endpoint: String, interfaceName: String) throws {}
    func disable() throws {
        lock.withLock {
            _disableCallCount += 1
        }
    }
}

private struct FailingEnableFirewall: PFFirewallControlling {
    func antileakIsActive() -> Bool { false }
    func enable(endpoint: String, interfaceName: String) throws {
        throw HelperError.commandFailed("injected PF enable failure")
    }
    func disable() throws {}
}

private struct ActiveFirewall: PFFirewallControlling {
    func antileakIsActive() -> Bool { true }
    func enable(endpoint: String, interfaceName: String) throws {}
    func disable() throws {}
}

private final class AlwaysBrokenTunnelController: TunnelControlling, @unchecked Sendable {
    private(set) var bringDownCallCount = 0

    func bringUp(currentSession: HelperSession?, armAntiLeak: Bool, ownerPID: Int32?) throws -> HelperSession {
        currentSession ?? HelperSession(interfaceName: "utun9", endpoint: "1.1.1.1:51820")
    }

    func bringDown(currentSession: HelperSession?) throws {
        bringDownCallCount += 1
    }

    func repair(currentSession: HelperSession?) throws -> HelperSession? {
        currentSession
    }

    func refreshedSession(currentSession: HelperSession?) throws -> HelperSession? {
        currentSession
    }
}

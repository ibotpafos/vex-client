import Foundation
import XCTest
@testable import VEXNativeMac

// VEX_RUNTIME_METHOD_NAMES: runCommand sendCommandWithRetry ensureHelperReady interruptWithDisconnect shutdownForAppTermination refreshStatus beginHelperCommand finishHelperCommand ensureCurrentHelperCommand confirmConnect refreshConnectedStatusUntilStable isConnectCommand ensureOK

// The runner inserts the actual command pipeline. Installer and transport are
// deterministic dependencies; these tests never use an installer or socket.
@MainActor
final class HelperCommandFixture {
    typealias VpnConnectionState = HelperFixtureState
    typealias VpnStatus = HelperFixtureStatus
    var status = HelperFixtureStatus.disconnected
    var isBusy = false
    var message: String?
    var installState: Int?
    var lastConnectAdmissionRejected = false
    let client = HelperFixtureClient()
    let installer = HelperFixtureInstaller()
    var pollTask: Task<Void, Never>?
    var consecutiveStatusFailures = 0
    var helperReadinessValidated = false
    var helperCommandGeneration = 0
    var helperCommandOwnership = VpnOperationOwnership()
    let connectStabilizationDeadline: Duration = .milliseconds(600)
    let handshakePatienceDeadline: Duration = .seconds(8)

    // VEX_RUNTIME_PRODUCTION_METHODS

    func runUp(shouldConnect: @escaping () -> Bool = { true }) async {
        await runCommand("up owner_pid=fixture", busyState: .connecting,
                         successMessage: "connected", shouldConnect: shouldConnect)
    }
    func runDown() async {
        await runCommand("down", busyState: .disconnecting, successMessage: "disconnected")
    }
}

enum HelperFixtureState: Equatable { case connected, disconnected, connecting, disconnecting }
struct HelperFixtureStatus: Equatable {
    var state: HelperFixtureState
    var routeOk: Bool
    var socketExists: Bool
    var ipv6RouteExpected = false
    var ipv6RouteOk = true
    var routeConflictMessage: String? { nil }
    var isUsableConnectedStatus: Bool { state == .connected && routeOk && socketExists }
    static let disconnected = Self(state: .disconnected, routeOk: false, socketExists: false)
    init(state: HelperFixtureState, routeOk: Bool, socketExists: Bool) {
        self.state = state; self.routeOk = routeOk; self.socketExists = socketExists
    }
    init(helperResponse: String) {
        let connected = helperResponse == "connected"
        self.init(state: connected ? .connected : .disconnected,
                  routeOk: connected, socketExists: connected)
    }
    func withState(_ state: HelperFixtureState) -> Self {
        var copy = self; copy.state = state; return copy
    }
}
@MainActor
final class HelperFixtureInstaller {
    var installedState = 1
    var gates: [Int: RecoveryGate] = [:]
    var errors: [Int: Error] = [:]
    private(set) var calls = 0
    func ensureReady(allowAdminInstall: Bool) async throws {
        calls += 1
        let call = calls
        if let gate = gates[call] { await gate.pause() }
        if let error = errors[call] { throw error }
    }
}
@MainActor
final class HelperFixtureClient {
    var upGates: [Int: RecoveryGate] = [:]
    var downGates: [Int: RecoveryGate] = [:]
    var statusGates: [Int: RecoveryGate] = [:]
    var upErrors: [Int: Error] = [:]
    private(set) var commands: [String] = []
    private(set) var upCalls = 0
    private(set) var downCalls = 0
    private(set) var statusCalls = 0
    private(set) var silentDisconnectCalls = 0
    var connected = false
    func send(_ command: String, timeoutSeconds: Double = 10) async throws -> String {
        commands.append(command)
        if command.hasPrefix("up") {
            upCalls += 1
            let call = upCalls
            if let gate = upGates[call] { await gate.pause() }
            if let error = upErrors[call] { throw error }
            connected = true
        } else if command == "down" || command == "shutdown" {
            downCalls += 1
            let call = downCalls
            if let gate = downGates[call] { await gate.pause() }
            connected = false
        }
        return "ok"
    }
    func sendExpectingOK(_ command: String, timeoutSeconds: Double = 10) async throws {
        _ = try await send(command, timeoutSeconds: timeoutSeconds)
    }
    func silentDisconnect(releaseAntiLeak: Bool) async {
        silentDisconnectCalls += 1
        _ = try? await send("down")
    }
    func sendStatus() async throws -> String {
        statusCalls += 1
        let snapshot = connected ? "connected" : "disconnected"
        if let gate = statusGates[statusCalls] { await gate.pause() }
        return snapshot
    }
}

enum VEXUserFacingText {
    static func status(_ text: String) -> String? { text }
}
// Retry classification is an unchanged dependency of the extracted pipeline.
enum VEXHelperError: LocalizedError {
    case readFailed, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .readFailed: return "could not read helper response"
        case .commandFailed(let text): return text
        }
    }
}
private extension Error {
    var isRetryableConnectFailure: Bool {
        if let error = self as? VEXHelperError, case .readFailed = error { return true }
        return false
    }
}

final class VpnHelperCallerTests: XCTestCase {
    @MainActor
    func testStopDuringInitialInstallerReadinessCannotSendLateUp() async throws {
        let helper = HelperCommandFixture(), gate = RecoveryGate()
        helper.installer.gates[1] = gate
        let old = Task { await helper.runUp() }
        try await gate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        gate.release()
        await old.value
        XCTAssertEqual(helper.client.upCalls, 0)
        XCTAssertEqual(helper.client.downCalls, 1)
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.message, "VPN отключен.")
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testStopDuringRetryReadinessCannotResendUp() async throws {
        let helper = HelperCommandFixture(), gate = RecoveryGate()
        helper.client.upErrors[1] = VEXHelperError.readFailed
        helper.installer.gates[2] = gate
        let old = Task { await helper.runUp() }
        try await gate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        gate.release()
        await old.value
        XCTAssertEqual(helper.client.upCalls, 1)
        XCTAssertEqual(helper.client.downCalls, 1)
        XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.message, "VPN отключен.")
        XCTAssertFalse(helper.helperReadinessValidated)
    }

    @MainActor
    func testRevokedAccountPredicateDuringInitialAndRetryReadinessCannotSendUp() async throws {
        for retry in [false, true] {
            let helper = HelperCommandFixture(), gate = RecoveryGate()
            var allowed = true
            helper.installer.gates[retry ? 2 : 1] = gate
            if retry { helper.client.upErrors[1] = VEXHelperError.readFailed }
            let old = Task { await helper.runUp(shouldConnect: { allowed }) }
            try await gate.awaitEntry()
            allowed = false
            helper.message = "new-session"
            helper.status = .disconnected
            gate.release()
            await old.value
            XCTAssertEqual(helper.client.upCalls, retry ? 1 : 0)
            XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
            XCTAssertEqual(helper.message, "new-session")
            XCTAssertEqual(helper.status.state, .disconnected)
            XCTAssertFalse(helper.helperReadinessValidated)
        }
    }

    @MainActor
    func testCancelledReadinessCannotSendUpOrRunFailureCleanup() async throws {
        let helper = HelperCommandFixture(), gate = RecoveryGate()
        helper.installer.gates[1] = gate
        let old = Task { await helper.runUp() }
        try await gate.awaitEntry()
        old.cancel()
        gate.release()
        await old.value
        XCTAssertEqual(helper.client.upCalls, 0)
        XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
        XCTAssertNil(helper.message)
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testExplicitDownStillRunsWhenCallerTaskWasCancelled() async throws {
        let helper = HelperCommandFixture(), gate = RecoveryGate()
        helper.client.connected = true
        helper.installer.gates[1] = gate
        let stop = Task { await helper.runDown() }
        try await gate.awaitEntry()
        stop.cancel()
        gate.release()
        await stop.value
        XCTAssertEqual(helper.client.commands, ["down"])
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.message, "disconnected")
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testShutdownInvalidatesPendingUp() async throws {
        let helper = HelperCommandFixture(), gate = RecoveryGate()
        helper.installer.gates[1] = gate
        let old = Task { await helper.runUp() }
        try await gate.awaitEntry()
        await helper.shutdownForAppTermination()
        gate.release()
        await old.value
        XCTAssertEqual(helper.client.commands, ["shutdown"])
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testOldCommandCompletionCannotReleaseReplacementBusyOwner() async throws {
        let helper = HelperCommandFixture(), oldGate = RecoveryGate(), newGate = RecoveryGate()
        helper.installer.gates = [1: oldGate, 2: newGate]
        let old = Task { await helper.runUp() }
        try await oldGate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        let replacement = Task { await helper.runUp() }
        try await newGate.awaitEntry()
        oldGate.release()
        await old.value
        XCTAssertTrue(helper.isBusy)
        XCTAssertEqual(helper.status.state, .connecting)
        XCTAssertEqual(helper.client.upCalls, 0)
        newGate.release()
        await replacement.value
        XCTAssertEqual(helper.client.upCalls, 1)
        XCTAssertEqual(helper.status.state, .connected)
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testStaleCommandFailureCannotDisconnectOrPublishOverReplacement() async throws {
        let helper = HelperCommandFixture(), upGate = RecoveryGate(), newGate = RecoveryGate()
        helper.client.upGates[1] = upGate
        helper.client.upErrors[1] = VEXHelperError.commandFailed("old failure")
        helper.installer.gates[2] = newGate
        let old = Task { await helper.runUp() }
        try await upGate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        let replacement = Task { await helper.runUp() }
        try await newGate.awaitEntry()
        helper.message = "replacement"
        upGate.release()
        await old.value
        XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
        XCTAssertEqual(helper.client.downCalls, 1)
        XCTAssertEqual(helper.message, "replacement")
        XCTAssertEqual(helper.status.state, .connecting)
        XCTAssertTrue(helper.isBusy)
        newGate.release()
        await replacement.value
        XCTAssertEqual(helper.client.upCalls, 2)
        XCTAssertEqual(helper.status.state, .connected)
    }

    @MainActor
    func testInterruptedDownOwnsBusyUntilItsCompletion() async throws {
        let helper = HelperCommandFixture(), installerGate = RecoveryGate(), downGate = RecoveryGate()
        helper.installer.gates[1] = installerGate
        helper.client.downGates[1] = downGate
        let old = Task { await helper.runUp() }
        try await installerGate.awaitEntry()
        let stop = Task { await helper.interruptWithDisconnect(releaseAntiLeak: true) }
        try await downGate.awaitEntry()
        installerGate.release()
        await old.value
        XCTAssertTrue(helper.isBusy)
        XCTAssertEqual(helper.status.state, .disconnecting)
        XCTAssertEqual(helper.client.upCalls, 0)
        downGate.release()
        await stop.value
        XCTAssertFalse(helper.isBusy)
        XCTAssertEqual(helper.status.state, .disconnected)
    }

    @MainActor
    func testOldStatusResponseCannotRepublishConnectedAfterStop() async throws {
        let helper = HelperCommandFixture(), statusGate = RecoveryGate()
        helper.client.statusGates[1] = statusGate
        let old = Task { await helper.runUp() }
        try await statusGate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        statusGate.release()
        await old.value
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.message, "VPN отключен.")
        XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
    }

    @MainActor
    func testOrdinaryPollCannotRepublishConnectedAfterCompletedDown() async throws {
        let helper = HelperCommandFixture(), statusGate = RecoveryGate()
        helper.client.connected = true
        helper.client.statusGates[1] = statusGate
        let poll = Task { await helper.refreshStatus(quiet: true) }
        try await statusGate.awaitEntry()
        await helper.interruptWithDisconnect(releaseAntiLeak: true)
        statusGate.release()
        await poll.value
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.message, "VPN отключен.")
        XCTAssertEqual(helper.client.downCalls, 1)
        XCTAssertFalse(helper.isBusy)
    }

    @MainActor
    func testCurrentConnectionAndRetryStillConnect() async {
        for retry in [false, true] {
            let helper = HelperCommandFixture()
            if retry { helper.client.upErrors[1] = VEXHelperError.readFailed }
            await helper.runUp()
            XCTAssertEqual(helper.client.upCalls, retry ? 2 : 1)
            XCTAssertEqual(helper.installer.calls, retry ? 2 : 1)
            XCTAssertEqual(helper.status.state, .connected)
            XCTAssertEqual(helper.message, "connected")
            XCTAssertEqual(helper.client.silentDisconnectCalls, 0)
            XCTAssertFalse(helper.isBusy)
        }
    }

    @MainActor
    func testCurrentFailureStillCleansUpAndRejectsInvalidProfileWithoutDown() async {
        for invalid in [false, true] {
            let helper = HelperCommandFixture()
            helper.client.upErrors[1] = VEXHelperError.commandFailed(invalid ? "VPN_CONFIG_INVALID" : "actual failure")
            await helper.runUp()
            XCTAssertEqual(helper.lastConnectAdmissionRejected, invalid)
            XCTAssertEqual(helper.client.silentDisconnectCalls, invalid ? 0 : 1)
            XCTAssertTrue(helper.message?.contains(invalid ? "VPN_CONFIG_INVALID" : "actual failure") == true)
            XCTAssertFalse(helper.isBusy)
        }
    }
}

import Foundation
import XCTest
@testable import VEXNativeMac

// VEX_RUNTIME_METHOD_NAMES: recoverTunnelIfNeeded restoreActiveTunnelIfHelperIsConnected connectVPN performConnectVPN disconnectVPN performDisconnectVPN toggleVPNPower switchConnectedVPNLocation beginVpnOperation finishVpnOperation invalidateVpnOperation ensureConnectStillDesired sessionUserId clearActiveTunnelRouteState finishInterruptedVpnStop ensureProfileSession prepareSelectedProfile

// The portable runner inserts the named, unmodified production methods at the
// marker below. Only dependencies are fake; no helper, network or stores run.
@MainActor
final class VEXAppState {
    var session: RecoverySession? = .init(user: .init(id: "account-a"), accessToken: "token-a")
    var desiredVpnState: RecoveryDesiredState = .connected
    var vpnOperationGeneration = 17
    var profileAccountGeneration = 4
    var vpnOperationOwnership = VpnOperationOwnership()
    var autoRecoveryEnabled = true
    var isVpnBusy = false
    var antiLeakEnabled = true
    var activeTunnel: RecoveryTunnel? = .original
    var activeResilienceRoute: RecoveryRoute? = nil
    var activeResiliencePolicy: RecoveryPolicy? = nil
    var dynamicRouteEngine = RecoveryRouteEngine()
    var statusMessage: String?
    var selectedLocation: RecoveryLocation? = .init(displayName: "Fixture")
    var selectedLocationId = "de"
    var targetLocationId = "de"
    var routingMode = "full_tunnel"
    var allowsAutomaticFailover = false
    var serverSidebarOperation = RecoverySidebarOperation.idle
    let autopilotService = RecoveryAutopilot()
    let diagnosticsService = RecoveryDiagnostics()
    let api = RecoveryAPI()
    lazy var profileService = RecoveryProfiles(state: self)
    var diagnosticsGate: RecoveryGate?
    var restoreGate: RecoveryGate?
    var profileGates: [RecoveryGate] = []
    var profileErrors: [Int: Error] = [:]
    var profileCalls = 0
    var diagnosticsCalls = 0
    var restoreTunnel = RecoveryTunnel.original
    var isRestoring = false
    var accessToken: String? { session?.accessToken }

    // VEX_RUNTIME_PRODUCTION_METHODS

    func runRestore(_ status: RecoveryStatus) async {
        isRestoring = true
        defer { isRestoring = false }
        await restoreActiveTunnelIfHelperIsConnected(status)
    }
    func runSwitch(using helper: RecoveryHelper) async -> Bool {
        await switchConnectedVPNLocation(using: helper)
    }
    func replaceSession(userId: String) {
        vpnOperationGeneration += 1
        profileAccountGeneration += 1
        session = .init(user: .init(id: userId), accessToken: "replacement-token")
        activeTunnel = .replacement
        statusMessage = "replacement-state"
    }
    private func authenticatedAccessToken() async -> String? { accessToken }
    private func ensureEntitlementForConnect(accessToken: String) async -> (String, RecoveryEntitlement)? {
        (accessToken, .init(hasPaidAccess: true))
    }
    func resolveProfileForAuthenticatedSession(accessToken: String, locationId: String,
        routingMode: String, forceRefresh: Bool,
        prevalidatedEntitlement: RecoveryEntitlement? = nil) async throws -> (RecoveryTunnel, String) {
        profileCalls += 1
        let call = profileCalls
        if call <= profileGates.count { await profileGates[call - 1].pause() }
        if let error = profileErrors[call] { throw error }
        return (.init(locationId: locationId, device: .init(id: "device-\(call)"),
                      endpoint: "fixture:51820"), accessToken)
    }
    private func connectWithAutopilot(initialTunnel: RecoveryTunnel, accessToken: String,
        accountUserId: String, helper: RecoveryHelper, generation: Int) async throws -> RecoveryTunnel {
        try ensureConnectStillDesired(generation: generation)
        await helper.connect(antiLeakEnabled: antiLeakEnabled)
        return initialTunnel
    }
    private func connectErrorMessage(_ error: Error) -> String { error.localizedDescription }
    private func shouldSwitchConnectedTunnel(for status: RecoveryStatus) -> Bool { false }
    private func tunnel(_ tunnel: RecoveryTunnel, matches status: RecoveryStatus) -> Bool {
        status.isUsableConnectedStatus && tunnel.endpoint == status.endpoint
    }
    private func tunnelHealthLooksStale(_ status: RecoveryStatus) -> Bool { status.stale }
    private func runtimeRouteFailureObserved(status: RecoveryStatus, healthReasons: [String]) -> Bool { status.stale }
    private func dynamicRouteTransport(_ route: RecoveryRoute) -> String { "fixture" }
    private func submitRouteDiagnostics(connectionEvent: String, transportFrom: String,
        transportTo: String?, status: String, helperStatus: RecoveryStatus) {}
    private func submitDiagnostics(reason: String, status: String, helperStatus: RecoveryStatus,
        samples: [String: String]) async {
        diagnosticsCalls += 1
        if let diagnosticsGate { await diagnosticsGate.pause() }
    }
}

typealias VEXHelperModel = RecoveryHelper
typealias VpnStatus = RecoveryStatus
typealias VpnDeviceUsage = RecoveryUsage

enum RecoveryDesiredState { case connected, disconnected }
enum RecoveryState { case connected, disconnected, connecting, disconnecting
    var rawValue: String { String(describing: self) }
}
struct RecoveryStatus {
    var state = RecoveryState.connected
    var stale = true
    var endpoint: String? = "fixture:51820"
    var isUsableConnectedStatus: Bool { state == .connected }
}
struct RecoveryUser { var id: String }
struct RecoverySession { var user: RecoveryUser; var accessToken: String }
struct RecoveryDevice { var id: String }
struct RecoveryLocation { var displayName: String }
struct RecoveryTunnel {
    var locationId: String
    var device: RecoveryDevice
    var endpoint: String?
    static let original = Self(locationId: "de", device: .init(id: "original-device"), endpoint: "fixture:51820")
    static let replacement = Self(locationId: "fr", device: .init(id: "replacement-device"), endpoint: "replacement:51820")
}
struct RecoveryEntitlement { var hasPaidAccess: Bool }
struct RecoveryUsage {
    var connectionStatus: String? = "connected"
    var secondsSinceHandshake: Int? = 0
}
struct RecoveryRoute {}
struct RecoveryPolicy {}
struct RecoveryRouteEngine { mutating func recordFailure(_ route: RecoveryRoute, policy: RecoveryPolicy) {} }
struct RecoveryAssessment {
    var userMessage = "recovering"
    var diagnosticStatus = "network"
    var canFailover = false
    var samples: [String: String] = [:]
}
enum RecoverySidebarOperation {
    case idle, preparingRoute, connecting, verifying, failed(String), verified(String)
}
enum VpnAutopilotRuntimeError: LocalizedError {
    case connectFailed(String)
    var errorDescription: String? { if case .connectFailed(let text) = self { return text }; return nil }
}
struct LastTunnelEndpointStore { func save(_ endpoint: String, locationId: String) {} }

@MainActor
final class RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func awaitEntry() async throws {
        for _ in 0..<5_000 { if entered { return }; await Task.yield() }
        throw NSError(domain: "RecoveryFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Production method did not reach expected suspension"])
    }
}

@MainActor
final class RecoveryAutopilot {
    var gate: RecoveryGate?
    private(set) var usageCalls = 0
    func usage(accessToken: String, deviceId: String?) async -> RecoveryUsage? {
        usageCalls += 1
        if let gate { await gate.pause() }
        return .init()
    }
    func healthReasons(status: RecoveryStatus, usage: RecoveryUsage?) -> [String] {
        if status.state == .disconnected { return ["local_status_disconnected"] }
        return status.stale ? ["stale_local_handshake"] : []
    }
    func assess(healthReasons: [String], status: RecoveryStatus) -> RecoveryAssessment { .init() }
}

@MainActor
final class RecoveryHelper {
    var status = RecoveryStatus()
    var isBusy = false
    var message: String?
    var downGate: RecoveryGate?
    var interruptGate: RecoveryGate?
    private(set) var downCalls = 0
    private(set) var upCalls = 0
    func disconnect(releaseAntiLeak: Bool) async {
        isBusy = true
        downCalls += 1
        status.state = .disconnecting
        if let downGate { await downGate.pause() }
        status.state = .disconnected
        isBusy = false
    }
    func interruptWithDisconnect(releaseAntiLeak: Bool) async {
        downCalls += 1
        status.state = .disconnecting
        if let interruptGate { await interruptGate.pause() }
        status.state = .disconnected
    }
    func connect(antiLeakEnabled: Bool, shouldConnect: @escaping () -> Bool = { true }) async {
        guard shouldConnect() else { return }
        upCalls += 1; status.state = .connected; status.stale = false
    }
}

final class RecoveryDiagnostics: @unchecked Sendable {
    func captureNetwork(accessToken: String, deviceId: String, vpnState: String) async {}
}
final class RecoveryAPI: @unchecked Sendable {
    func reportVpnConnect(accessToken: String, tunnel: RecoveryTunnel) async {}
    func reportVpnDisconnect(accessToken: String, tunnel: RecoveryTunnel?, reason: String) async {}
}
@MainActor
final class RecoveryProfiles {
    unowned let state: VEXAppState
    init(state: VEXAppState) { self.state = state }
    func resolveProfile(accessToken: String, userId: String, locationId: String,
        routingMode: String, forceRefresh: Bool, writeHelperConfig: Bool) async throws -> RecoveryTunnel {
        if state.isRestoring {
            if let gate = state.restoreGate { await gate.pause() }
            return state.restoreTunnel
        }
        return try await state.resolveProfileForAuthenticatedSession(accessToken: accessToken,
            locationId: locationId, routingMode: routingMode, forceRefresh: forceRefresh).0
    }
    func writeHelperConfig(for tunnel: RecoveryTunnel, shouldWrite: () -> Bool) async throws {
        if !shouldWrite() { throw CancellationError() }
    }
}

final class VpnRecoveryCallerTests: XCTestCase {
    @MainActor
    func testUserStopDuringUsageCannotRestartVpn() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.autopilotService.gate = gate
        let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        gate.release()
        await recovery.value
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        XCTAssertEqual(helper.upCalls, 0)
        XCTAssertEqual(state.profileCalls, 0)
        XCTAssertEqual(state.diagnosticsCalls, 0)
    }

    @MainActor
    func testUserStopDuringDiagnosticsCannotRestartVpn() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.diagnosticsGate = gate
        let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        gate.release()
        await recovery.value
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        XCTAssertEqual(helper.downCalls, 1)
        XCTAssertEqual(helper.upCalls, 0)
        XCTAssertEqual(state.profileCalls, 0)
    }

    @MainActor
    func testUserStopDuringRecoveryDownCannotRestartVpn() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        helper.downGate = gate
        let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        gate.release()
        await recovery.value
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        XCTAssertEqual(helper.upCalls, 0)
        XCTAssertEqual(state.profileCalls, 0)
    }

    @MainActor
    func testSecondMenuStopDuringDownClearsOwnedRouteMetadata() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        helper.downGate = gate
        let stopping = Task { await state.disconnectVPN(using: helper) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        gate.release()
        await stopping.value
        XCTAssertNil(state.activeTunnel)
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(helper.upCalls, 0)
        XCTAssertFalse(state.isVpnBusy)
    }

    @MainActor
    func testSessionReplacementAndSameAccountReloginFenceEveryRecoveryAwait() async throws {
        for user in ["account-b", "account-a"] {
            for boundary in ["usage", "diagnostics", "down"] {
                let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
                if boundary == "usage" { state.autopilotService.gate = gate }
                if boundary == "diagnostics" { state.diagnosticsGate = gate }
                if boundary == "down" { helper.downGate = gate }
                let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
                try await gate.awaitEntry()
                state.replaceSession(userId: user)
                gate.release()
                await recovery.value
                XCTAssertEqual(state.session?.user.id, user, boundary)
                XCTAssertEqual(state.activeTunnel?.device.id, "replacement-device", boundary)
                XCTAssertEqual(state.statusMessage, "replacement-state", boundary)
                XCTAssertEqual(helper.upCalls, 0, boundary)
                XCTAssertEqual(state.profileCalls, 0, boundary)
            }
        }
    }

    @MainActor
    func testCancellationAndDisabledRecoveryCannotCreateNewIntent() async throws {
        for boundary in ["usage", "diagnostics", "down"] {
            for cancel in [true, false] {
                let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
                if boundary == "usage" { state.autopilotService.gate = gate }
                if boundary == "diagnostics" { state.diagnosticsGate = gate }
                if boundary == "down" { helper.downGate = gate }
                let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
                try await gate.awaitEntry()
                if cancel { recovery.cancel() } else { state.autoRecoveryEnabled = false }
                gate.release()
                await recovery.value
                XCTAssertEqual(helper.upCalls, 0, boundary)
                XCTAssertEqual(state.profileCalls, 0, boundary)
            }
        }
    }

    @MainActor
    func testHealthyTunnelIsNotRestarted() async {
        let state = VEXAppState(), helper = RecoveryHelper()
        helper.status.stale = false
        await state.recoverTunnelIfNeeded(using: helper)
        XCTAssertEqual(helper.downCalls, 0)
        XCTAssertEqual(helper.upCalls, 0)
    }

    @MainActor
    func testLegitimateStaleTunnelRecoversOnce() async {
        let state = VEXAppState(), helper = RecoveryHelper()
        await state.recoverTunnelIfNeeded(using: helper)
        XCTAssertEqual(helper.downCalls, 1)
        XCTAssertEqual(helper.upCalls, 1)
        XCTAssertEqual(state.profileCalls, 1)
        XCTAssertEqual(state.desiredVpnState, .connected)
        XCTAssertFalse(state.isVpnBusy)
    }

    @MainActor
    func testStoppedIntentCannotAdoptOldConnectedHelperStatus() async {
        let state = VEXAppState(), helper = RecoveryHelper()
        state.desiredVpnState = .disconnected
        await state.recoverTunnelIfNeeded(using: helper)
        XCTAssertEqual(state.autopilotService.usageCalls, 0)
        XCTAssertEqual(helper.downCalls, 0)
        XCTAssertEqual(helper.upCalls, 0)
    }

    @MainActor
    func testSameAccountTokenRefreshPreservesRecovery() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.autopilotService.gate = gate
        let recovery = Task { await state.recoverTunnelIfNeeded(using: helper) }
        try await gate.awaitEntry()
        state.session?.accessToken = "refreshed-token"
        gate.release()
        await recovery.value
        XCTAssertEqual(helper.upCalls, 1)
    }

    @MainActor
    func testMatchingColdStartRestoreAdoptsConnectedIntent() async {
        let state = VEXAppState(), helper = RecoveryHelper()
        state.activeTunnel = nil
        state.desiredVpnState = .disconnected
        await state.runRestore(helper.status)
        XCTAssertEqual(state.activeTunnel?.device.id, "original-device")
        XCTAssertEqual(state.desiredVpnState, .connected)
        await state.recoverTunnelIfNeeded(using: helper)
        XCTAssertEqual(helper.upCalls, 1)
    }

    @MainActor
    func testStopDuringRestoreCannotAdoptOrClearNewState() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.activeTunnel = nil
        state.desiredVpnState = .disconnected
        state.restoreGate = gate
        let restore = Task { await state.runRestore(helper.status) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        let message = state.statusMessage
        gate.release()
        await restore.value
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        XCTAssertNil(state.activeTunnel)
        XCTAssertEqual(state.statusMessage, message)
    }

    @MainActor
    func testSessionReplacementDuringRestoreLeavesReplacementState() async throws {
        for user in ["account-b", "account-a"] {
            let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
            state.activeTunnel = nil
            state.desiredVpnState = .disconnected
            state.restoreGate = gate
            let restore = Task { await state.runRestore(helper.status) }
            try await gate.awaitEntry()
            state.replaceSession(userId: user)
            gate.release()
            await restore.value
            XCTAssertEqual(state.activeTunnel?.device.id, "replacement-device")
            XCTAssertEqual(state.statusMessage, "replacement-state")
            XCTAssertEqual(state.desiredVpnState, .disconnected)
        }
    }

    @MainActor
    func testLateConnectCancellationAndFailureCannotDisconnectReplacement() async throws {
        for failure in [false, true] {
            let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
            state.activeTunnel = nil
            helper.status.state = .disconnected
            state.profileGates = [gate]
            if failure { state.profileErrors[1] = NSError(domain: "fixture", code: 500) }
            let old = Task { await state.connectVPN(using: helper) }
            try await gate.awaitEntry()
            await state.toggleVPNPower(using: helper)
            await state.connectVPN(using: helper)
            let replacement = state.activeTunnel?.device.id
            let stops = helper.downCalls
            gate.release()
            await old.value
            XCTAssertEqual(helper.status.state, .connected)
            XCTAssertEqual(state.activeTunnel?.device.id, replacement)
            XCTAssertEqual(helper.downCalls, stops)
        }
    }

    @MainActor
    func testOldConnectCompletionCannotReleaseReplacementBusyOwner() async throws {
        let state = VEXAppState(), helper = RecoveryHelper()
        let oldGate = RecoveryGate(), replacementGate = RecoveryGate()
        state.activeTunnel = nil
        helper.status.state = .disconnected
        state.profileGates = [oldGate, replacementGate]
        let old = Task { await state.connectVPN(using: helper) }
        try await oldGate.awaitEntry()
        await state.toggleVPNPower(using: helper)
        let replacement = Task { await state.connectVPN(using: helper) }
        try await replacementGate.awaitEntry()
        oldGate.release()
        await old.value
        XCTAssertTrue(state.isVpnBusy)
        replacementGate.release()
        await replacement.value
        XCTAssertFalse(state.isVpnBusy)
        XCTAssertEqual(helper.upCalls, 1)
    }

    @MainActor
    func testPowerOnDuringInterruptedStopHandsOffOnlyToLatestIntent() async throws {
        let state = VEXAppState(), helper = RecoveryHelper()
        let oldProfile = RecoveryGate(), replacementProfile = RecoveryGate(), down = RecoveryGate()
        state.activeTunnel = nil
        helper.status.state = .disconnected
        state.profileGates = [oldProfile, replacementProfile]
        let old = Task { await state.connectVPN(using: helper) }
        try await oldProfile.awaitEntry()
        helper.interruptGate = down
        let stop = Task { await state.toggleVPNPower(using: helper) }
        try await down.awaitEntry()
        await state.toggleVPNPower(using: helper)
        let requestedGeneration = state.vpnOperationGeneration
        down.release()
        try await replacementProfile.awaitEntry()
        XCTAssertEqual(state.vpnOperationGeneration, requestedGeneration)
        oldProfile.release()
        await old.value
        XCTAssertTrue(state.isVpnBusy)
        replacementProfile.release()
        await stop.value
        XCTAssertEqual(helper.upCalls, 1)
        XCTAssertEqual(helper.downCalls, 1)
        XCTAssertEqual(state.desiredVpnState, .connected)
        XCTAssertFalse(state.isVpnBusy)
    }

    @MainActor
    func testMenuStopDuringPendingSwitchStopsLiveTunnel() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.targetLocationId = "fr"
        state.profileGates = [gate]
        let switching = Task { await state.runSwitch(using: helper) }
        try await gate.awaitEntry()
        await state.disconnectVPN(using: helper)
        XCTAssertEqual(helper.status.state, .disconnected)
        XCTAssertEqual(state.desiredVpnState, .disconnected)
        gate.release()
        let switched = await switching.value
        XCTAssertFalse(switched)
        XCTAssertNil(state.activeTunnel)
        XCTAssertEqual(helper.upCalls, 0)
    }

    @MainActor
    func testLateSwitchCancellationCannotClearReplacementTunnel() async throws {
        let state = VEXAppState(), helper = RecoveryHelper(), gate = RecoveryGate()
        state.targetLocationId = "fr"
        state.profileGates = [gate]
        let old = Task { await state.runSwitch(using: helper) }
        try await gate.awaitEntry()
        await state.toggleVPNPower(using: helper)
        await state.connectVPN(using: helper)
        let replacement = state.activeTunnel?.device.id
        gate.release()
        let switched = await old.value
        XCTAssertFalse(switched)
        XCTAssertEqual(state.activeTunnel?.device.id, replacement)
        XCTAssertEqual(helper.status.state, .connected)
    }
}

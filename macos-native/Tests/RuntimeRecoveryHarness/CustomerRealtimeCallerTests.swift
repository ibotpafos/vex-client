import Foundation
import XCTest
@testable import VEXNativeMac

// VEX_RUNTIME_METHOD_NAMES: startCustomerRealtime resetCustomerNotificationSession isCurrentCustomerRealtimeSession sessionUserId resetAuthenticatedState
// Production callbacks are inserted verbatim; streams, notifications and refresh
// are fakes. No account, API, macOS permission prompt or helper is accessed.
@MainActor
final class RealtimeCallerState {
    var session: SessionUserSession? = .init(accessToken: "token-a", user: .initial)
    var profileAccountGeneration = 4
    var customerRealtimeGeneration = 0
    var customerRealtimeConnected = false
    var customerNotificationPolicy = CustomerNotificationPolicy()
    let customerNotifications = RealtimeNotifications()
    let api = RealtimeAPI()
    var customerRealtimeService: CustomerRealtimeService?
    var customerFallbackTask: Task<Void, Never>?
    static let customerFallbackIntervalNanoseconds: UInt64 = 60_000_000_000
    var refreshGate: RecoveryGate?
    var refreshCalls = 0
    var sessionRetryCalls = 0
    var automaticFailoverLocationId: String?
    var user: SessionUserValue? = .initial
    var entitlement: String?
    var billingSummary: String?
    var billingPayments: [String] = []
    var authError: String?
    var billingError: String?
    var canUnlockStoredSession = false
    var statusMessage: String?
    let sessionStore = RealtimeSessionStore()

    // VEX_RUNTIME_PRODUCTION_METHODS

    func start(_ token: String = "token-a") { startCustomerRealtime(accessToken: token) }
    func logout() {
        resetAuthenticatedState(clearsSessionStore: true, message: "signed-out", authError: nil)
    }
    private func invalidateProfileWorkForAccountChange() { profileAccountGeneration += 1 }
    private func clearActiveTunnelRouteState() {}
    func stop() {
        resetCustomerNotificationSession()
        customerRealtimeService?.stop()
        customerFallbackTask?.cancel()
        customerFallbackTask = nil
    }
    func replaceAccount(_ userId: String = "account-b") {
        stop()
        profileAccountGeneration += 1
        session = .init(accessToken: "replacement-token",
            user: .init(id: userId, email: "replacement@example.test"))
        customerRealtimeConnected = false
    }
    private func refreshCustomerState() async {
        refreshCalls += 1
        if let refreshGate { await refreshGate.pause() }
    }
    private func refreshSessionForRetry() async -> String? {
        sessionRetryCalls += 1
        return session?.accessToken
    }
}

struct RealtimeAPI { let baseURL = URL(string: "https://api.example.test")! }
struct RealtimeSessionStore {
    func clearSession() throws {}
    func hasStoredNativeSession() -> Bool { false }
}
@MainActor
final class RealtimeNotifications {
    var delivered: [CustomerNotificationPayload] = []
    func resetSession() { delivered.removeAll() }
    func deliver(_ notices: [CustomerNotificationPayload]) async { delivered += notices }
}
@MainActor
final class CustomerRealtimeService {
    let onStatus: @MainActor (Bool) -> Void
    let onSessionRejected: @MainActor () async -> Void
    let onEvent: @MainActor (CustomerRealtimeEvent, CustomerRealtimeMetadata) async -> Void
    init(baseURL: URL, onStatus: @escaping @MainActor (Bool) -> Void,
         onSessionRejected: @escaping @MainActor () async -> Void,
         onEvent: @escaping @MainActor (CustomerRealtimeEvent, CustomerRealtimeMetadata) async -> Void) {
        self.onStatus = onStatus; self.onSessionRejected = onSessionRejected; self.onEvent = onEvent
    }
    func start(accessToken: String) {}
    func stop() {}
    func change(id: String = "change-1", type: String = "customer.change") async {
        let event = CustomerRealtimeEvent(type: type, id: id, data: #"{"domain":"support","version":1}"#)
        guard let metadata = CustomerRealtimeMetadata.parse(type: type, data: event.data) else { return }
        await onEvent(event, metadata)
    }
}

final class CustomerRealtimeCallerTests: XCTestCase {
    @MainActor
    func testCurrentStreamRefreshesAndDeduplicatesNotices() async throws {
        let state = RealtimeCallerState()
        defer { state.stop() }
        state.start()
        let stream = try XCTUnwrap(state.customerRealtimeService)
        stream.onStatus(true)
        await stream.change()
        await stream.change()
        XCTAssertTrue(state.customerRealtimeConnected)
        XCTAssertEqual(state.refreshCalls, 2)
        XCTAssertEqual(state.customerNotifications.delivered.count, 1)
    }

    @MainActor
    func testOldCallbacksCannotAffectReplacementAccountOrSameAccountLogin() async throws {
        for userId in ["account-a", "account-b"] {
            let state = RealtimeCallerState()
            defer { state.stop() }
            state.start()
            let retired = try XCTUnwrap(state.customerRealtimeService)
            state.replaceAccount(userId)
            state.start("replacement-token")
            retired.onStatus(true)
            await retired.onSessionRejected()
            await retired.change()
            await retired.change(type: "customer.session.revoked")
            XCTAssertFalse(state.customerRealtimeConnected)
            XCTAssertEqual(state.refreshCalls, 0)
            XCTAssertEqual(state.sessionRetryCalls, 0)
            XCTAssertTrue(state.customerNotifications.delivered.isEmpty)
        }
    }

    @MainActor
    func testAccountReplacementDuringRefreshCannotDeliverOldNotice() async throws {
        let state = RealtimeCallerState(), gate = RecoveryGate()
        defer { state.stop() }
        state.start()
        state.refreshGate = gate
        let retired = try XCTUnwrap(state.customerRealtimeService)
        let event = Task { await retired.change() }
        try await gate.awaitEntry()
        state.replaceAccount()
        gate.release()
        await event.value
        XCTAssertTrue(state.customerNotifications.delivered.isEmpty)
    }

    @MainActor
    func testStreamRestartRetiresCallbacksEvenWithSameAccountAndToken() async throws {
        let state = RealtimeCallerState()
        defer { state.stop() }
        state.start()
        let retired = try XCTUnwrap(state.customerRealtimeService)
        state.start()
        retired.onStatus(true)
        await retired.onSessionRejected()
        await retired.change()
        XCTAssertFalse(state.customerRealtimeConnected)
        XCTAssertEqual(state.refreshCalls, 0)
        XCTAssertEqual(state.sessionRetryCalls, 0)
        XCTAssertTrue(state.customerNotifications.delivered.isEmpty)
    }

    @MainActor
    func testRealLogoutResetsNoticesAndRetiresStreamCallbacks() async throws {
        let state = RealtimeCallerState()
        defer { state.stop() }
        state.start()
        let retired = try XCTUnwrap(state.customerRealtimeService)
        await retired.change()
        XCTAssertEqual(state.customerNotifications.delivered.count, 1)
        let generation = state.customerRealtimeGeneration
        state.logout()
        XCTAssertNil(state.session)
        XCTAssertTrue(state.customerNotifications.delivered.isEmpty)
        XCTAssertGreaterThan(state.customerRealtimeGeneration, generation)
        await retired.change(id: "late-change")
        XCTAssertEqual(state.refreshCalls, 1)
        XCTAssertTrue(state.customerNotifications.delivered.isEmpty)
    }
}

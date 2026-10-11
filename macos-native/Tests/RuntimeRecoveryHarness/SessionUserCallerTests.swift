import Foundation
import XCTest
@testable import VEXNativeMac

// VEX_RUNTIME_METHOD_NAMES: loadUser withSessionRetry sessionUserId

// The runner inserts the real callers verbatim. A gated API supplies responses
// after logout/login; no request, credential store or helper runs.
@MainActor
final class SessionUserCallerState {
    var session: SessionUserSession? = .init(accessToken: "token-a", user: .initial)
    var user: SessionUserValue? = .initial
    var profileAccountGeneration = 4
    var statusMessage: String? = "current-state"
    var refreshCalls = 0
    var expiryCalls = 0
    let api = SessionUserAPI()

    // VEX_RUNTIME_PRODUCTION_METHODS

    func runLoadUser(_ token: String = "token-a") async { await loadUser(token) }
    private func authenticatedAccessToken() async -> String? { session?.accessToken }
    private func refreshSessionForRetry() async -> String? {
        refreshCalls += 1
        session?.accessToken = "refreshed-token"
        return session?.accessToken
    }
    private func expireAuthenticatedSession(message: String) {
        expiryCalls += 1
        profileAccountGeneration += 1
        session = nil
        user = nil
        statusMessage = message
    }
    func signOutForFixture() {
        profileAccountGeneration += 1
        session = nil
        user = nil
        statusMessage = "signed-out"
    }
    func replaceLoginForFixture(userId: String) {
        signOutForFixture()
        profileAccountGeneration += 1
        let replacement = SessionUserValue(id: userId, email: "new@example.test")
        session = .init(accessToken: "replacement-token", user: replacement)
        user = replacement
        statusMessage = "replacement-state"
    }
}

struct SessionUserValue: Equatable {
    var id: String
    var email: String
    static let initial = Self(id: "account-a", email: "initial@example.test")
    static let fresh = Self(id: "account-a", email: "fresh@example.test")
}
struct SessionUserSession {
    var accessToken: String
    var user: SessionUserValue
}
private enum SessionUserFailure: LocalizedError, Equatable {
    case unauthorized, offline
    var errorDescription: String? {
        self == .unauthorized ? "expired token" : "network offline"
    }
}
private extension Error {
    var isUnauthorizedAPIError: Bool { (self as? SessionUserFailure) == .unauthorized }
}

@MainActor
final class SessionUserAPI {
    var gate: RecoveryGate?
    var replies: [Result<SessionUserValue, Error>] = [.success(.fresh)]
    private(set) var requestTokens: [String] = []
    func me(accessToken: String) async throws -> SessionUserValue {
        let index = requestTokens.count
        requestTokens.append(accessToken)
        guard index < replies.count else {
            throw NSError(domain: "SessionUserFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected extra user request"])
        }
        let reply = replies[index]
        if index == 0, let gate { await gate.pause() }
        return try reply.get()
    }
}

final class SessionUserCallerTests: XCTestCase {
    @MainActor
    func testCurrentSuccessfulUserResponsePublishesUser() async {
        let state = SessionUserCallerState()
        await state.runLoadUser()
        XCTAssertEqual(state.user, .fresh)
        XCTAssertEqual(state.session?.accessToken, "token-a")
        XCTAssertEqual(state.api.requestTokens, ["token-a"])
        XCTAssertEqual(state.statusMessage, "current-state")
    }

    @MainActor
    func testOldSuccessfulUserResponseCannotOverwriteReplacementLogin() async throws {
        for userId in ["account-a", "account-b"] {
            let state = SessionUserCallerState(), gate = RecoveryGate()
            state.api.gate = gate
            let oldRequest = Task { await state.runLoadUser() }
            try await gate.awaitEntry()
            state.replaceLoginForFixture(userId: userId)
            let replacement = state.user
            gate.release()
            await oldRequest.value
            XCTAssertEqual(state.user, replacement, "Retired user data must not replace a later login")
            XCTAssertEqual(state.session?.user, replacement)
            XCTAssertEqual(state.session?.accessToken, "replacement-token")
            XCTAssertEqual(state.statusMessage, "replacement-state")
            XCTAssertEqual(state.refreshCalls, 0)
            XCTAssertEqual(state.expiryCalls, 0)
        }
    }

    @MainActor
    func testOldSuccessfulUserResponseCannotRestoreSignedOutUser() async throws {
        let state = SessionUserCallerState(), gate = RecoveryGate()
        state.api.gate = gate
        let oldRequest = Task { await state.runLoadUser() }
        try await gate.awaitEntry()
        state.signOutForFixture()
        gate.release()
        await oldRequest.value
        XCTAssertNil(state.user)
        XCTAssertNil(state.session)
        XCTAssertEqual(state.statusMessage, "signed-out")
    }

    @MainActor
    func testLateUserFailuresCannotRefreshExpireOrClobberReplacementLogin() async throws {
        for userId in ["account-a", "account-b"] {
            for failure in [SessionUserFailure.unauthorized, .offline] {
                let state = SessionUserCallerState(), gate = RecoveryGate()
                state.api.gate = gate
                state.api.replies = [.failure(failure)]
                let oldRequest = Task { await state.runLoadUser() }
                try await gate.awaitEntry()
                state.replaceLoginForFixture(userId: userId)
                let replacement = state.user
                gate.release()
                await oldRequest.value
                XCTAssertEqual(state.user, replacement)
                XCTAssertEqual(state.session?.accessToken, "replacement-token")
                XCTAssertEqual(state.statusMessage, "replacement-state")
                XCTAssertEqual(state.refreshCalls, 0)
                XCTAssertEqual(state.expiryCalls, 0)
                XCTAssertEqual(state.api.requestTokens, ["token-a"])
            }
        }
    }

    @MainActor
    func testCurrentUserFailureRemainsVisible() async {
        let state = SessionUserCallerState()
        state.api.replies = [.failure(SessionUserFailure.offline)]
        await state.runLoadUser()
        XCTAssertEqual(state.statusMessage, "network offline")
        XCTAssertEqual(state.user, .initial)
        XCTAssertEqual(state.refreshCalls, 0)
        XCTAssertEqual(state.expiryCalls, 0)
    }

    @MainActor
    func testCurrentUnauthorizedUserRequestRefreshesAndRetries() async {
        let state = SessionUserCallerState()
        state.api.replies = [.failure(SessionUserFailure.unauthorized), .success(.fresh)]
        await state.runLoadUser()
        XCTAssertEqual(state.user, .fresh)
        XCTAssertEqual(state.session?.accessToken, "refreshed-token")
        XCTAssertEqual(state.api.requestTokens, ["token-a", "refreshed-token"])
        XCTAssertEqual(state.refreshCalls, 1)
        XCTAssertEqual(state.expiryCalls, 0)
    }

    @MainActor
    func testRepeatedCurrentUnauthorizedUserRequestExpiresSession() async {
        let state = SessionUserCallerState()
        state.api.replies = [.failure(SessionUserFailure.unauthorized), .failure(SessionUserFailure.unauthorized)]
        await state.runLoadUser()
        XCTAssertNil(state.session)
        XCTAssertNil(state.user)
        XCTAssertEqual(state.refreshCalls, 1)
        XCTAssertEqual(state.expiryCalls, 1)
        XCTAssertEqual(state.api.requestTokens, ["token-a", "refreshed-token"])
    }
}

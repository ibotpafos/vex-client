import Foundation
import XCTest
@testable import VEXNativeMac

final class VEXSessionStoreTests: XCTestCase {
    func testBiometricSessionMigrationMovesBearerTokenToKeychainAndDeletesPlaintextFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vex-session-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileStore = AppSensitiveFileStore(directoryURL: directory)
        let keychain = InMemorySessionKeychain()
        let session = AuthSession(
            user: VEXUser(id: "usr_1", email: "user@example.com", status: "active"),
            accessToken: "bearer-token-must-not-remain-on-disk",
            expiresAt: nil,
            refreshToken: "refresh-token-must-not-remain-on-disk"
        )
        let payload = try JSONEncoder().encode(session)
        try fileStore.setData(payload, for: "vex.auth.session.v1")
        try fileStore.setData(payload, for: "vex.auth.session.history.v1")
        let store = VEXSessionStore(fileStore: fileStore, nativeKeychain: keychain, legacyKeychain: InMemorySessionKeychain())

        XCTAssertNil(store.loadSession(allowAuthenticationUI: false, requiresBiometricAuthentication: true))
        let storedPayload = try XCTUnwrap(keychain.payloads["vex.auth.session.v1"])
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: Data(storedPayload.utf8)), session)
        XCTAssertTrue(keychain.requiresBiometricAuthentication["vex.auth.session.v1"] ?? false)
        XCTAssertNil(fileStore.data(for: "vex.auth.session.v1"))
        XCTAssertNil(fileStore.data(for: "vex.auth.session.history.v1"))
        let persistedContents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
        XCTAssertFalse(persistedContents.contains(session.accessToken))
        XCTAssertEqual(store.loadSession(allowAuthenticationUI: true, requiresBiometricAuthentication: true), session)
    }

    func testClearSessionPreventsLegacySessionFromBeingRestored() throws {
        let identifier = UUID().uuidString
        let sessionKey = "vex.auth.session.v1"
        let historyKey = "vex.auth.session.history.v1"
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VEXSessionStoreTests-\(identifier)", isDirectory: true)
        let fileStore = AppSensitiveFileStore(directoryURL: directoryURL)
        let nativeKeychain = VEXKeychainStore(service: "test.vex.native.\(identifier)")
        let legacyKeychain = VEXKeychainStore(service: "test.vex.legacy.\(identifier)")
        let store = VEXSessionStore(
            fileStore: fileStore,
            nativeKeychain: nativeKeychain,
            legacyKeychain: legacyKeychain
        )
        let payload = """
        {"user":{"id":"usr_1","email":"user@example.com","status":"active"},"accessToken":"legacy-token"}
        """

        defer {
            try? legacyKeychain.delete(account: sessionKey)
            try? legacyKeychain.delete(account: historyKey)
            try? nativeKeychain.delete(account: sessionKey)
            try? nativeKeychain.delete(account: historyKey)
            try? FileManager.default.removeItem(at: directoryURL)
        }

        try legacyKeychain.setString(payload, for: sessionKey)

        XCTAssertEqual(store.loadSession()?.accessToken, "legacy-token")

        try store.clearSession()

        XCTAssertNil(store.loadSession())
    }
}

private final class InMemorySessionKeychain: VEXSessionKeychain {
    var payloads: [String: String] = [:]
    var requiresBiometricAuthentication: [String: Bool] = [:]

    func string(for account: String, allowAuthenticationUI: Bool) -> String? {
        payloads[account]
    }

    func setString(_ value: String, for account: String, requiresBiometricAuthentication: Bool) throws {
        payloads[account] = value
        self.requiresBiometricAuthentication[account] = requiresBiometricAuthentication
    }

    func delete(account: String) throws {
        payloads.removeValue(forKey: account)
        requiresBiometricAuthentication.removeValue(forKey: account)
    }

    func contains(account: String) -> Bool {
        payloads[account] != nil
    }
}

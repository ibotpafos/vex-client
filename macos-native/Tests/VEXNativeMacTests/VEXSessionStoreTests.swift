import Foundation
import XCTest
@testable import VEXNativeMac

final class VEXSessionStoreTests: XCTestCase {
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

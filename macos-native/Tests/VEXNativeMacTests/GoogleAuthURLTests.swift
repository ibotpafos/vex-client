import XCTest
import CryptoKit
@testable import VEXNativeMac

final class GoogleAuthURLTests: XCTestCase {
    @MainActor
    func testGoogleURLRetainsPKCEStateAndDefaultURLDoesNotForceProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AppSensitiveFileStore(directoryURL: directory)
        try files.setString("vexd_fixture", for: "vex.auth.device_id")
        let suite = "GoogleAuthURLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PKCEAuthService(apiBaseURL: URL(string: "https://example.invalid")!, defaults: defaults, identityStore: VEXDeviceIdentityStore(fileStore: files))
        let url = try service.makeWebAuthURL(mode: .login, provider: .google)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/auth/app")
        XCTAssertEqual(query["provider"], "google")
        XCTAssertEqual(query["client_id"], "vex_app")
        XCTAssertEqual(query["device_id"], "vexd_fixture")
        XCTAssertEqual(query["platform"], "macos")
        XCTAssertEqual(query["mode"], "login")
        XCTAssertEqual(query["state"], defaults.string(forKey: "vex.auth.pkce.state"))
        let verifier = try XCTUnwrap(defaults.string(forKey: "vex.auth.pkce.verifier"))
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(query["code_challenge"], challenge)
        let callback = URL(string: "vexguard://auth/callback?code=fixture&state=\(query["state"]!)")!
        XCTAssertEqual(try service.consumeVerifier(for: callback), verifier)
        XCTAssertThrowsError(try service.consumeVerifier(for: URL(string: "vexguard://auth/callback?code=fixture&state=wrong")!))
        let ordinary = try service.makeWebAuthURL(mode: .register)
        XCTAssertFalse(try XCTUnwrap(URLComponents(url: ordinary, resolvingAgainstBaseURL: false)?.queryItems).contains { $0.name == "provider" })
        service.clearVerifier()
        XCTAssertThrowsError(try service.consumeVerifier(for: callback))
    }
}

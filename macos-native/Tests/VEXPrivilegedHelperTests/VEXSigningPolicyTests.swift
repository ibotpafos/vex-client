import Foundation
import Security
import XCTest
@testable import VEXHelperCore

final class VEXSigningPolicyTests: XCTestCase {
    func testRequirementParsesAndPinsIdentityAndCertificate() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(SystemPeerAuthenticator.clientRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(SystemPeerAuthenticator.clientRequirement.contains("identifier \"app.vex.vpn.native\""))
        XCTAssertTrue(SystemPeerAuthenticator.clientRequirement.contains("certificate leaf = H\"c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e\""))
        XCTAssertTrue(SystemPeerAuthenticator.clientRequirement.contains("anchor apple generic"))
        XCTAssertEqual(SystemPeerAuthenticator.localCertificateSHA256, "441f6e9034ee7582c1ca3579ea805f91f68c3135ec2f59cddc00173fe689dca1")
    }

    func testUnsignedOrUnrelatedTestRunnerFailsPinnedRequirement() throws {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(SystemPeerAuthenticator.clientRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotEqual(SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags(rawValue: kSecCSStrictValidate), try XCTUnwrap(requirement)), errSecSuccess)
    }

    func testInvalidAuditTokenAndNonConsoleUIDFailClosed() {
        let auth = SystemPeerAuthenticator()
        XCTAssertFalse(auth.authenticate(PeerCredentials(pid: getpid(), auditToken: Data(), effectiveUID: getuid())))
        XCTAssertFalse(auth.authenticate(PeerCredentials(pid: getpid(), auditToken: Data(), effectiveUID: uid_t.max)))
    }
}

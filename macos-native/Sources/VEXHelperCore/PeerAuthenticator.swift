import Darwin
import CryptoKit
import Foundation
import Security
import SystemConfiguration

public struct PeerCredentials: Sendable {
    public let pid: Int32
    public let auditToken: Data
    public let effectiveUID: uid_t

    public init(pid: Int32, auditToken: Data, effectiveUID: uid_t) {
        self.pid = pid
        self.auditToken = auditToken
        self.effectiveUID = effectiveUID
    }
}

public protocol PeerAuthenticating: Sendable {
    func authenticate(_ peer: PeerCredentials) -> Bool
}

public struct SystemPeerAuthenticator: PeerAuthenticating {
    private let expectedBundleIdentifier: String
    private let expectedTeamIdentifier: String?
    private let expectedCertificateSHA256: String?
    private let allowAdHocClient: Bool

    public init(
        expectedBundleIdentifier: String = "app.vex.vpn.native",
        expectedTeamIdentifier: String? = ProcessInfo.processInfo.environment["VEX_EXPECTED_TEAM_ID"],
        expectedCertificateSHA256: String? = ProcessInfo.processInfo.environment["VEX_EXPECTED_CERT_SHA256"],
        allowAdHocClient: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.environment["VEX_HELPER_ALLOW_ADHOC_CLIENT"] == "1"
            #else
            false
            #endif
        }()
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedCertificateSHA256 = expectedCertificateSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.allowAdHocClient = allowAdHocClient
    }

    public func authenticate(_ peer: PeerCredentials) -> Bool {
        if peer.effectiveUID == 0 {
            return true
        }
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) != nil,
              consoleUID > 0,
              peer.effectiveUID == consoleUID else {
            return false
        }

        let attributes = [kSecGuestAttributeAudit as String: peer.auditToken] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSSigningInformation),
                  &information
              ) == errSecSuccess,
              let signing = information as? [String: Any],
              signing[kSecCodeInfoIdentifier as String] as? String == expectedBundleIdentifier else {
            return false
        }

        let actualTeamIdentifier = signing[kSecCodeInfoTeamIdentifier as String] as? String
        if let expectedTeamIdentifier, !expectedTeamIdentifier.isEmpty {
            return actualTeamIdentifier == expectedTeamIdentifier
        }
        if let expectedCertificateSHA256, !expectedCertificateSHA256.isEmpty {
            guard let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let leaf = certificates.first else {
                return false
            }
            let leafData = SecCertificateCopyData(leaf) as Data
            let actualFingerprint = SHA256.hash(data: leafData)
                .map { String(format: "%02x", $0) }
                .joined()
            return actualFingerprint == expectedCertificateSHA256
        }
        return allowAdHocClient && (actualTeamIdentifier == nil || actualTeamIdentifier?.isEmpty == true)
    }
}

func peerCredentials(for fd: Int32) -> PeerCredentials? {
    var token = audit_token_t()
    var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
    let tokenResult = withUnsafeMutablePointer(to: &token) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<audit_token_t>.size) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &tokenLength)
        }
    }
    guard tokenResult == 0, tokenLength == MemoryLayout<audit_token_t>.size else {
        return nil
    }

    let pid = audit_token_to_pid(token)
    let effectiveUID = audit_token_to_euid(token)
    var mutableToken = token
    let data = Data(bytes: &mutableToken, count: MemoryLayout<audit_token_t>.size)
    return PeerCredentials(pid: pid, auditToken: data, effectiveUID: effectiveUID)
}

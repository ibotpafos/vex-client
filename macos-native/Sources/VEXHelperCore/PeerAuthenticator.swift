import Darwin
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
    // Trust anchors are compiled in; caller/launchd environment cannot broaden them.
    public static let localCertificateSHA256 = "441f6e9034ee7582c1ca3579ea805f91f68c3135ec2f59cddc00173fe689dca1"
    public static let clientRequirement = "identifier \"app.vex.vpn.native\" and (certificate leaf = H\"c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e\" or (anchor apple generic and certificate leaf[subject.OU] = \"3JLW9XNU53\"))"

    public init() {}

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
              signing[kSecCodeInfoIdentifier as String] as? String == "app.vex.vpn.native" else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        // Evaluate the requirement against the live audit-token code, not a PID or path.
        return SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess

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

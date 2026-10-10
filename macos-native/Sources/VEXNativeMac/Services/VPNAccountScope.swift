import Foundation

protocol VEXDeviceIdentityKeychain {
    func string(for account: String, allowAuthenticationUI: Bool) -> String?
    func stringIfPresent(for account: String, allowAuthenticationUI: Bool) throws -> String?
    func setString(_ value: String, for account: String, requiresBiometricAuthentication: Bool) throws
}

enum VPNAccountScope {
    static func storageKey(_ prefix: String, accountUserId: String) throws -> String {
        guard !accountUserId.isEmpty else { throw VEXKeychainError.invalidValue }
        // Raw UTF8 hex remains injective on case-insensitive macOS volumes.
        let account = accountUserId.utf8.map { String(format: "%02x", $0) }.joined()
        return "\(prefix).account.\(account)"
    }
}

import Foundation
import LocalAuthentication
import Security

struct VEXKeychainStore {
    static let nativeService = "app.vex.vpn.native.sensitive-storage"
    static let legacyTauriService = "app.vex.vpn.desktop.sensitive-storage"

    let service: String

    init(service: String = VEXKeychainStore.nativeService) {
        self.service = service
    }

    func string(for account: String, allowAuthenticationUI: Bool = true) -> String? {
        guard let data = data(for: account, allowAuthenticationUI: allowAuthenticationUI) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(for account: String, allowAuthenticationUI: Bool = true) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    func setString(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try setData(data, for: account)
    }

    func setData(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw VEXKeychainError.status(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VEXKeychainError.status(addStatus)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VEXKeychainError.status(status)
        }
    }
}

enum VEXKeychainError: LocalizedError {
    case invalidValue
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "Некорректное значение Keychain."
        case .status(let status):
            return "Keychain error \(status)."
        }
    }
}

import Foundation

struct VEXSessionStore {
    private let sessionKey = "vex.auth.session.v1"
    private let historyKey = "vex.auth.session.history.v1"
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: any VEXSessionKeychain
    private let legacyKeychain: any VEXSessionKeychain

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: any VEXSessionKeychain = VEXKeychainStore(),
        legacyKeychain: any VEXSessionKeychain = VEXKeychainStore(service: VEXKeychainStore.legacyDesktopService)
    ) {
        self.fileStore = fileStore
        self.nativeKeychain = nativeKeychain
        self.legacyKeychain = legacyKeychain
    }

    func loadSession(
        allowAuthenticationUI: Bool = false,
        requiresBiometricAuthentication: Bool = false
    ) -> AuthSession? {
        if let session = migrateNativeKeychainSessionIfAvailable(
            allowAuthenticationUI: allowAuthenticationUI,
            requiresBiometricAuthentication: requiresBiometricAuthentication
        ) {
            return session
        }
        return migrateLegacySessionIfAvailable(
            allowAuthenticationUI: allowAuthenticationUI,
            requiresBiometricAuthentication: requiresBiometricAuthentication
        )
    }

    func hasStoredNativeSession() -> Bool {
        fileStore.data(for: sessionKey) != nil
            || fileStore.data(for: historyKey) != nil
            || nativeKeychain.contains(account: sessionKey)
            || nativeKeychain.contains(account: historyKey)
            || legacyKeychain.contains(account: sessionKey)
            || legacyKeychain.contains(account: historyKey)
    }

    func saveSession(_ session: AuthSession, requiresBiometricAuthentication: Bool = false) throws {
        let data = try JSONEncoder().encode(session)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try nativeKeychain.setString(
            payload,
            for: sessionKey,
            requiresBiometricAuthentication: requiresBiometricAuthentication
        )
        try? nativeKeychain.delete(account: historyKey)
        try deleteLegacyPlaintextFiles()
    }

    func clearSession() throws {
        try deleteLegacyPlaintextFiles()
        try? nativeKeychain.delete(account: sessionKey)
        try? nativeKeychain.delete(account: historyKey)
    }

    private func readLegacyPlaintextSession(key: String) -> AuthSession? {
        guard let payload = fileStore.string(for: key),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func migrateLegacySessionIfAvailable(
        allowAuthenticationUI: Bool,
        requiresBiometricAuthentication: Bool
    ) -> AuthSession? {
        if let session = readLegacyPlaintextSession(key: sessionKey) ?? readLegacyPlaintextSession(key: historyKey) {
            do {
                try saveSession(session, requiresBiometricAuthentication: requiresBiometricAuthentication)
                if requiresBiometricAuthentication && !allowAuthenticationUI {
                    return nil
                }
                return session
            } catch {
                return nil
            }
        }
        if let session = readLegacyKeychainSession(key: sessionKey, allowAuthenticationUI: allowAuthenticationUI)
            ?? readLegacyKeychainSession(key: historyKey, allowAuthenticationUI: allowAuthenticationUI) {
            do {
                try saveSession(session, requiresBiometricAuthentication: requiresBiometricAuthentication)
                try? legacyKeychain.delete(account: sessionKey)
                try? legacyKeychain.delete(account: historyKey)
                return session
            } catch {
                return nil
            }
        }
        return nil
    }

    private func migrateNativeKeychainSessionIfAvailable(
        allowAuthenticationUI: Bool,
        requiresBiometricAuthentication: Bool
    ) -> AuthSession? {
        guard let session = readNativeKeychainSession(key: sessionKey, allowAuthenticationUI: allowAuthenticationUI)
            ?? readNativeKeychainSession(key: historyKey, allowAuthenticationUI: allowAuthenticationUI) else {
            return nil
        }
        guard requiresBiometricAuthentication else { return session }
        do {
            try saveSession(session, requiresBiometricAuthentication: true)
            return allowAuthenticationUI ? session : nil
        } catch {
            return nil
        }
    }

    private func readNativeKeychainSession(key: String, allowAuthenticationUI: Bool) -> AuthSession? {
        guard let payload = nativeKeychain.string(for: key, allowAuthenticationUI: allowAuthenticationUI),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func readLegacyKeychainSession(key: String, allowAuthenticationUI: Bool) -> AuthSession? {
        guard let payload = legacyKeychain.string(for: key, allowAuthenticationUI: allowAuthenticationUI),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func deleteLegacyPlaintextFiles() throws {
        try fileStore.delete(sessionKey)
        try fileStore.delete(historyKey)
    }
}

import Foundation

struct VEXSessionStore {
    private let sessionKey = "vex.auth.session.v1"
    private let historyKey = "vex.auth.session.history.v1"
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: VEXKeychainStore
    private let legacyKeychain: VEXKeychainStore

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: VEXKeychainStore = VEXKeychainStore(),
        legacyKeychain: VEXKeychainStore = VEXKeychainStore(service: VEXKeychainStore.legacyTauriService)
    ) {
        self.fileStore = fileStore
        self.nativeKeychain = nativeKeychain
        self.legacyKeychain = legacyKeychain
    }

    func loadSession() -> AuthSession? {
        if let session = readSession(key: sessionKey) {
            return session
        }
        if let session = readSession(key: historyKey) {
            return session
        }
        if let session = migrateNativeKeychainSessionIfAvailable() {
            return session
        }
        return migrateLegacySessionIfAvailable()
    }

    func hasStoredNativeSession() -> Bool {
        fileStore.data(for: sessionKey) != nil
            || fileStore.data(for: historyKey) != nil
            || nativeKeychain.data(for: sessionKey, allowAuthenticationUI: false) != nil
            || nativeKeychain.data(for: historyKey, allowAuthenticationUI: false) != nil
            || legacyKeychain.data(for: sessionKey, allowAuthenticationUI: false) != nil
            || legacyKeychain.data(for: historyKey, allowAuthenticationUI: false) != nil
    }

    func saveSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try fileStore.setString(payload, for: sessionKey)
        try? fileStore.setString(payload, for: historyKey)
        try? nativeKeychain.setString(payload, for: sessionKey)
        try? nativeKeychain.setString(payload, for: historyKey)
    }

    func clearSession() throws {
        try fileStore.delete(sessionKey)
        try fileStore.delete(historyKey)
        try? nativeKeychain.delete(account: sessionKey)
        try? nativeKeychain.delete(account: historyKey)
    }

    private func readSession(key: String) -> AuthSession? {
        guard let payload = fileStore.string(for: key),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func migrateNativeKeychainSessionIfAvailable() -> AuthSession? {
        if let session = readNativeKeychainSession(key: sessionKey) ?? readNativeKeychainSession(key: historyKey) {
            try? saveSession(session)
            return session
        }
        return nil
    }

    private func migrateLegacySessionIfAvailable() -> AuthSession? {
        if let session = readLegacySession(key: sessionKey) ?? readLegacySession(key: historyKey) {
            try? saveSession(session)
            return session
        }
        return nil
    }

    private func readNativeKeychainSession(key: String) -> AuthSession? {
        guard let payload = nativeKeychain.string(for: key, allowAuthenticationUI: false),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func readLegacySession(key: String) -> AuthSession? {
        guard let payload = legacyKeychain.string(for: key, allowAuthenticationUI: false),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
}

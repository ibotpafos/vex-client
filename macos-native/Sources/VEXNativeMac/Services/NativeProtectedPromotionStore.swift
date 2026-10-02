import CryptoKit
import Foundation

/// One bounded private metadata intent per account/install namespace. No config,
/// private key, raw account identity, access token, or owner token is written.
struct NativeProtectedPromotionStore {
    private let root: URL

    init(fileManager: FileManager = .default, appDataURL: URL? = nil) {
        root = appDataURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("VEX Native", isDirectory: true)
    }

    static func fingerprint(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8); var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func name(accountID: String, installationID: String) throws -> String {
        guard !accountID.isEmpty, !installationID.isEmpty, accountID.utf8.count <= 512,
              installationID.utf8.count <= 512, !accountID.utf8.contains(0), !installationID.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return "promotion-" + Self.fingerprint(["vex-protected-promotion-v1", accountID, installationID]) + ".json"
    }

    func hasRecord(accountID: String, installationID: String) throws -> Bool {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = try name(accountID: accountID, installationID: installationID)
        try store.ensureDirectory()
        return try store.read(name) != nil
    }

    @MainActor
    func persistence(accountID: String, installationID: String, scopeFingerprint: String, generation: Int)
        throws -> NativeProtectedReplacementCoordinator.Persistence {
        let name = try name(accountID: accountID, installationID: installationID)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        try store.ensureDirectory()
        return .init(scopeFingerprint: scopeFingerprint, processInstanceID: NativeProtectedReplacementCoordinator.processInstanceID,
            generation: generation, load: { try store.read(name) }, save: { data in
                try NativeProtectedReplacementCoordinator.requireValidPersistentPayload(data,
                    scopeFingerprint: scopeFingerprint, generation: generation)
                if let existing = try store.read(name) {
                    try NativeProtectedReplacementCoordinator.requireSamePersistentIdentity(existing, data)
                }
                try store.write(data, name: name)
                guard try store.read(name) == data else { throw CocoaError(.fileWriteUnknown) }
            }, remove: { expected in
                guard try store.read(name) == expected else { throw CocoaError(.fileWriteFileExists) }
                try store.remove(name)
                guard try store.read(name) == nil else { throw CocoaError(.fileWriteUnknown) }
            })
    }

    /// Explicit account cleanup only, never deletion as a substitute for proof.
    func purge(accountID: String, installationID: String) throws {
        try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
            .remove(name(accountID: accountID, installationID: installationID))
    }
}

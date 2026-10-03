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
    func restartIntent(accountID: String, installationID: String) throws -> NativeProtectedReplacementCoordinator.RestartIntent? {
        guard let data = try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
            .read(name(accountID: accountID, installationID: installationID)) else { return nil }
        return try NativeProtectedReplacementCoordinator.restartIntent(data)
    }

    @MainActor
    func restartReceiptMetadata(accountID: String, installationID: String) throws -> NativeProtectedReplacementCoordinator.Receipt? {
        guard let data = try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
            .read(name(accountID: accountID, installationID: installationID)) else { return nil }
        return try NativeProtectedReplacementCoordinator.restartReceiptMetadata(data)
    }

    @MainActor
    func stageConsentExpected(accountID: String, installationID: String,
        original: NativeProtectedReplacementCoordinator.RestartIntent) throws -> Bool {
        guard let data = try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
            .read(name(accountID: accountID, installationID: installationID)) else { throw CocoaError(.fileReadCorruptFile) }
        return try NativeProtectedReplacementCoordinator.stageConsentExpected(data, original: original)
    }

    /// Only after an exact original-owner root cancellation ACK was durably
    /// retained. Scope may have changed, but no consumed journal/receipt is erased.
    @MainActor
    func removeCancelledStageIntent(accountID: String, installationID: String,
        original: NativeProtectedReplacementCoordinator.RestartIntent, isCurrent: () -> Bool) throws {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = try name(accountID: accountID, installationID: installationID)
        guard !Task.isCancelled, isCurrent() else { throw CocoaError(.fileWriteUnknown) }
        guard let data = try store.read(name) else { return }
        try NativeProtectedReplacementCoordinator.requireUnconsumedStageIntent(data, original: original)
        guard !Task.isCancelled, isCurrent(), try store.read(name) == data else { throw CocoaError(.fileWriteFileExists) }
        try store.remove(name)
        guard try store.read(name) == nil else { throw CocoaError(.fileWriteUnknown) }
    }

    @MainActor
    func terminalPayload(accountID: String, installationID: String) throws -> Data? {
        try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384).read(name(accountID: accountID, installationID: installationID))
    }
    @MainActor
    func removeRetiredIntent(accountID: String, installationID: String,
        intent: NativeProtectedReplacementCoordinator.RestartIntent, nonceSHA256: String,
        receipt: NativeProtectedReplacementCoordinator.Receipt?, isCurrent: () -> Bool) throws {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384), name = try name(accountID: accountID, installationID: installationID)
        guard !Task.isCancelled, isCurrent(), intent.isValid,
              NativeProtectedReplacementCoordinator.validDigest(nonceSHA256) else { throw CocoaError(.fileWriteUnknown) }
        guard let data = try store.read(name) else { return } // exact WAL is required by caller
            try NativeProtectedReplacementCoordinator.requireTerminalPersistentPayload(data, intent: intent, receipt: receipt)
            guard NativeProtectedReplacementCoordinator.digest(String(decoding: data, as: UTF8.self)) == nonceSHA256,
              !Task.isCancelled, isCurrent(), try store.read(name) == data else { throw CocoaError(.fileWriteFileExists) }
        try store.remove(name); guard try store.read(name) == nil else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Not a generic save override. The caller already reverified signed/current
    /// material and the authenticated root receipt using its ephemeral new owner.
    /// Compare/readback fences every private write, including exact retry.
    @MainActor
    func rebindAfterAuthorizedRestart(accountID: String, installationID: String,
        original: NativeProtectedReplacementCoordinator.RestartIntent,
        receipt: NativeProtectedReplacementCoordinator.Receipt, scopeFingerprint: String,
        isCurrent: () -> Bool) throws -> Data {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = try name(accountID: accountID, installationID: installationID)
        guard !Task.isCancelled, isCurrent(), let existing = try store.read(name) else { throw CocoaError(.fileReadCorruptFile) }
        let rebound = try NativeProtectedReplacementCoordinator.reboundRestartIntent(existing,
            original: original, receipt: receipt, scopeFingerprint: scopeFingerprint)
        guard !Task.isCancelled, isCurrent(), try store.read(name) == existing else { throw CocoaError(.fileWriteFileExists) }
        if rebound != existing { try store.write(rebound, name: name) }
        guard !Task.isCancelled, isCurrent(), try store.read(name) == rebound else { throw CocoaError(.fileWriteUnknown) }
        return rebound
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

    @MainActor
    func rebindJournalAfterAuthorizedRestart(accountID: String, installationID: String,
        original: NativeProtectedReplacementCoordinator.RestartIntent,
        ownership: NativeProtectedReplacementCoordinator.JournalOwnership, scopeFingerprint: String,
        isCurrent: () -> Bool) throws -> Data {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = try name(accountID: accountID, installationID: installationID)
        guard !Task.isCancelled, isCurrent(), let existing = try store.read(name) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try NativeProtectedReplacementCoordinator.reboundJournalIntent(existing,
            original: original, ownership: ownership, scopeFingerprint: scopeFingerprint)
        guard !Task.isCancelled, isCurrent(), try store.read(name) == existing else { throw CocoaError(.fileWriteFileExists) }
        if data != existing { try store.write(data, name: name) }
        guard !Task.isCancelled, isCurrent(), try store.read(name) == data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

}

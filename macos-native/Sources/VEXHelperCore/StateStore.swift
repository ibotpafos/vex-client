import Foundation

public final class HelperStateStore: @unchecked Sendable {
    private let fileSystem: HelperFileSystem
    private let paths: HelperPathsLayout
    private let dateProvider: DateProviding

    public init(
        fileSystem: HelperFileSystem,
        paths: HelperPathsLayout = .init(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.fileSystem = fileSystem
        self.paths = paths
        self.dateProvider = dateProvider
    }

    public func ensureDirectories() throws {
        try fileSystem.createDirectory(at: paths.helperDirectory)
        try fileSystem.createDirectory(at: paths.runtimeDirectory)
    }

    public func loadSession() -> HelperSession? {
        if let text = try? fileSystem.readText(at: paths.sessionStatePath), let session = HelperSession(payload: text) {
            return session
        }
        guard let interfaceName = try? fileSystem.readText(at: paths.interfacePath).trimmingCharacters(in: .whitespacesAndNewlines),
              !interfaceName.isEmpty
        else {
            return nil
        }
        let endpoint = (try? fileSystem.readText(at: paths.endpointPath).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return HelperSession(
            interfaceName: interfaceName,
            endpoint: endpoint,
            socketExists: fileSystem.fileExists(at: paths.runtimeSocketPath(for: interfaceName)),
            antiLeakArmed: antileakIsPersisted()
        )
    }

    public func persistSession(_ session: HelperSession) throws {
        try ensureDirectories()
        try fileSystem.writeTextAtomically(session.payload, to: paths.sessionStatePath, mode: 0o600)
        try fileSystem.writeTextAtomically("\(session.interfaceName)\n", to: paths.interfacePath, mode: 0o600)
        try fileSystem.writeTextAtomically("\(session.endpoint)\n", to: paths.endpointPath, mode: 0o600)
    }

    public func clearSession() {
        try? fileSystem.removeItem(at: paths.sessionStatePath)
        try? fileSystem.removeItem(at: paths.interfacePath)
        try? fileSystem.removeItem(at: paths.endpointPath)
    }

    public func loadOwnerSession() -> OwnerSession? {
        guard let payload = try? fileSystem.readText(at: paths.ownerSessionPath) else {
            return nil
        }
        return OwnerSession(payload: payload)
    }

    public func persistOwnerSession(_ session: OwnerSession) throws {
        try ensureDirectories()
        try fileSystem.writeTextAtomically(session.payload, to: paths.ownerSessionPath, mode: 0o600)
    }

    public func clearOwnerSession() {
        try? fileSystem.removeItem(at: paths.ownerSessionPath)
    }

    public func antileakIsPersisted() -> Bool {
        fileSystem.fileExists(at: paths.antileakStatePath)
            || fileSystem.fileExists(at: paths.legacyAntileakStatePath)
            || (fileSystem.fileSize(at: paths.antileakAnchorPath) ?? 0) > 0
    }

    public func operationInProgress(staleAfter: TimeInterval) -> Bool {
        guard let modified = fileSystem.modificationDate(at: paths.operationLockPath) else {
            return false
        }
        return dateProvider.now.timeIntervalSince(modified) <= staleAfter
    }

    public func withOperationLock<T>(staleAfter: TimeInterval, _ body: () throws -> T) throws -> T {
        try ensureDirectories()
        if let modified = fileSystem.modificationDate(at: paths.operationLockPath),
           dateProvider.now.timeIntervalSince(modified) > staleAfter {
            try? fileSystem.removeItem(at: paths.operationLockPath)
        }
        if fileSystem.fileExists(at: paths.operationLockPath) {
            throw HelperError.operationInProgress
        }
        try fileSystem.writeTextAtomically("pid=\(getpid())\n", to: paths.operationLockPath, mode: 0o600)
        defer { try? fileSystem.removeItem(at: paths.operationLockPath) }
        return try body()
    }
}

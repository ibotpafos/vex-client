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

    public var protectedReplacementRecoveryPending: Bool {
        // Any remaining journal, including corrupt, unreadable, symlinked or
        // committed-but-not-removed data, belongs to explicit recovery only.
        fileSystem.pathPresence(at: paths.helperDirectory + "/replacement-journal.state") != .absent
    }

    public var protectedOwnershipTransferPending: Bool {
        let path = paths.helperDirectory + "/protected-owner-transfer.state"
        guard fileSystem.pathPresence(at: path) != .absent else { return false }
        // Expiry/corruption/lookup failure is NOT permission to tear down the
        // tunnel or attach a dead owner. Only explicit transfer/cancellation
        // clears this fence. A strict completion receipt is evidence only.
        guard fileSystem.pathPresence(at: path) == .present,
              let text = try? fileSystem.readPrivateText(at: path, maxBytes: 16_384),
              let record = try? ProtectedOwnerTransferRecord.decode(text) else { return true }
        return record.phase != "transferred"
    }

    public var protectedOperationRecoveryPending: Bool {
        protectedReplacementRecoveryPending || protectedOwnershipTransferPending
    }

    public func requireNoPendingOwnerTransfer() throws {
        guard !protectedOwnershipTransferPending else { throw HelperError.ownerTransferPending }
    }

    public func requireNoPendingReplacement() throws {
        try requireNoPendingOwnerTransfer()
        guard !protectedReplacementRecoveryPending else {
            throw HelperError.replacementRecoveryPending
        }
    }

    /// Ordinary operations must never consume protected-replacement evidence.
    /// The second check closes the race with a replacement acquiring the same
    /// lease after our fast, non-mutating preflight check.
    public func withOrdinaryOperationLock<T>(staleAfter: TimeInterval, _ body: () throws -> T) throws -> T {
        try requireNoPendingReplacement()
        return try withOperationLock(staleAfter: staleAfter) {
            try requireNoPendingReplacement()
            return try body()
        }
    }

    /// Startup cleanup may run when directory creation failed. Still take the
    /// same kernel lease and recheck the journal; inability to lock is not
    /// permission to mutate network state. No marker/directory writes required.
    public func withOrdinaryEmergencyCleanupLease<T>(_ body: () throws -> T) throws -> T {
        try requireNoPendingReplacement()
        let lease = try HelperOperationLease.acquire(path: paths.operationLockPath, fileSystem: fileSystem)
        defer { withExtendedLifetime(lease) {} }
        try requireNoPendingReplacement()
        return try body()
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
        if HelperOperationLease.isHeld(path: paths.operationLockPath, fileSystem: fileSystem) {
            return true
        }
        guard let modified = fileSystem.modificationDate(at: paths.operationLockPath) else {
            return false
        }
        return dateProvider.now.timeIntervalSince(modified) <= staleAfter
    }

    public func withOperationLock<T>(staleAfter: TimeInterval, _ body: () throws -> T) throws -> T {
        try ensureDirectories()
        let lease = try HelperOperationLease.acquire(path: paths.operationLockPath, fileSystem: fileSystem)
        // Retain the descriptor until all persistent cleanup is complete.
        defer { withExtendedLifetime(lease) {} }
        if fileSystem.fileExists(at: paths.operationLockPath) {
            let expired = fileSystem.modificationDate(at: paths.operationLockPath).map {
                dateProvider.now.timeIntervalSince($0) > staleAfter
            } ?? false
            if fileSystem is LocalFileSystem {
                let previous = try fileSystem.readText(at: paths.operationLockPath)
                let lines = previous.split(separator: "\n", omittingEmptySubsequences: false)
                let kernelMarker = lines.count == 4 && lines[3].isEmpty
                    && lines[0].hasPrefix("pid=")
                    && Int32(lines[0].dropFirst(4)).map { $0 > 1 } == true
                    && lines[1] == "lease=kernel-v1"
                    && lines[2].hasPrefix("token=")
                    && UUID(uuidString: String(lines[2].dropFirst(6))) != nil
                if !kernelMarker {
                    // Legacy helpers do not hold flock. Reclaim only their
                    // exact known marker after expiry AND confirmed PID death.
                    // Malformed/unreadable markers and EPERM remain blocked.
                    guard expired, lines.count == 2, lines[1].isEmpty,
                          lines[0].hasPrefix("pid="),
                          let pid = Int32(lines[0].dropFirst(4)), pid > 1,
                          previous == "pid=\(pid)\n" else {
                        throw HelperError.operationInProgress
                    }
                    let result = kill(pid, 0)
                    guard result == -1 && errno == ESRCH else {
                        throw HelperError.operationInProgress
                    }
                }
                // An acquired kernel lease proves the previous v1 operation
                // no longer holds the inode, even if its marker is still fresh.
            } else if !expired {
                throw HelperError.operationInProgress
            }
            try fileSystem.removeItem(at: paths.operationLockPath)
        }
        if fileSystem.fileExists(at: paths.operationLockPath) {
            throw HelperError.operationInProgress
        }
        let marker = "pid=\(getpid())\nlease=kernel-v1\ntoken=\(UUID().uuidString)\n"
        try fileSystem.writeTextAtomically(marker, to: paths.operationLockPath, mode: 0o600)
        defer {
            // Never remove a marker that was replaced by another owner.
            if (try? fileSystem.readText(at: paths.operationLockPath)) == marker {
                try? fileSystem.removeItem(at: paths.operationLockPath)
            }
        }
        return try body()
    }
}

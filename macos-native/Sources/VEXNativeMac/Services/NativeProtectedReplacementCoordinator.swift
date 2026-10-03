import CryptoKit
import Foundation

/// No installer, generic connect/disconnect, endpoint fallback or cached status
/// is reachable from this transaction. Dependencies are also the offline seam.
@MainActor
final class NativeProtectedReplacementCoordinator {
    struct Dependencies {
        var isCurrent: () -> Bool
        var send: (String, Int) async throws -> String
        var stageCandidate: () throws -> Void
        var restoreSource: () throws -> Void
        var wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 500_000_000) }
        var persistence: Persistence? = nil
        // Uses this transaction's already-authenticated send port while its
        // helper wrapper owns busy. Never nest another public busy wrapper.
        var stageConsent: ((RestartIntent, @escaping (String, Int) async throws -> String) async throws -> Void)? = nil
    }

    /// Metadata only: exact hashes/nonce and current process+intent, never keys,
    /// raw tokens, config, or permission to attach a different helper owner.
    struct Persistence {
        let scopeFingerprint: String
        let processInstanceID: String
        let generation: Int
        var load: () throws -> Data?
        var save: (Data) throws -> Void
        var remove: (Data) throws -> Void
    }
    static let processInstanceID = UUID().uuidString

    enum Failure: Error {
        case staleIntent, sourceMismatch, invalidResponse, recoveryPending, sourceRestored, handshakeTimeout, persistenceUnavailable
    }

    struct JournalOwnership: Equatable {
        let transactionID: String
        let sourceSHA256: String
        let candidateSHA256: String
        let ownerTokenSHA256: String
    }

    struct Receipt: Codable, Equatable {
        let transactionID: String
        let candidateSHA256: String
        let latestHandshake: UInt64
        let ownerTokenSHA256: String

        init(transactionID: String, candidateSHA256: String, latestHandshake: UInt64, ownerTokenSHA256: String = "") {
            self.transactionID = transactionID
            self.candidateSHA256 = candidateSHA256
            self.latestHandshake = latestHandshake
            self.ownerTokenSHA256 = ownerTokenSHA256
        }
    }

    private struct Transaction: Codable, Equatable {
        let id: String
        let source: String
        let candidate: String
        let owner: String
        let supportsCommitReceipt: Bool
        var commitResponseUncertain = false
        // Optional for byte-compatible legacy intents. Once set it never
        // downgrades; true means no replace RPC has been sent by this client.
        var stageConsentPending: Bool? = nil
        var metadata: String {
            "transaction_id=\(id) source_sha256=\(source) candidate_sha256=\(candidate) owner_token_sha256=\(owner)"
        }
    }
    private struct StoredIntent: Codable {
        let schema: Int
        let scopeFingerprint: String
        let processInstanceID: String
        let generation: Int
        let transaction: Transaction
        let receipt: Receipt?
    }
    /// Public metadata for an explicitly consented restart. Decoding this tuple
    /// grants no admission, ownership, receipt or permission to stage a profile.
    struct RestartIntent: Codable, Equatable {
        let transactionID: String
        let sourceSHA256: String
        let candidateSHA256: String
        let ownerTokenSHA256: String
        let scopeFingerprint: String
        let processInstanceID: String
        let generation: Int
        var isValid: Bool {
            UUID(uuidString: transactionID)?.uuidString == transactionID
                && UUID(uuidString: processInstanceID)?.uuidString == processInstanceID
                && [sourceSHA256, candidateSHA256, ownerTokenSHA256, scopeFingerprint].allSatisfy(Self.validDigest)
                && sourceSHA256 != candidateSHA256 && generation >= 0
        }
        private static func validDigest(_ text: String) -> Bool {
            NativeProtectedReplacementCoordinator.validDigest(text)
        }
    }
    // TODO: Isolated Mac crash/power-loss acceptance remains unavailable.
    // Retained metadata, consent or a dead PID alone never authorizes adoption.
    private var pending: Transaction?
    private var committed: (transaction: Transaction, receipt: Receipt)?
    private var activePersistence: Persistence?
    private(set) var hasUnconfirmedDurableWrite = false
    var hasPendingTransaction: Bool { pending != nil }

    /// Only after root cancelled the exact UNCONSUMED consent and its private
    /// nonce was removed. No helper/network port and no consumed evidence reset.
    func completeCancelledStage(_ original: RestartIntent) throws {
        guard original.isValid, original.processInstanceID == Self.processInstanceID,
              pending == nil, committed == nil else { throw Failure.recoveryPending }
        if let p = activePersistence {
            guard p.scopeFingerprint == original.scopeFingerprint, p.generation == original.generation,
                  p.processInstanceID == original.processInstanceID, try p.load() == nil else { throw Failure.recoveryPending }
        }
        activePersistence = nil
        hasUnconfirmedDurableWrite = false
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func verifyAdmittedSource(_ expectedSHA256: String, isCurrent: () -> Bool,
        send: (String, Int) async throws -> String) async throws -> String {
        guard !Task.isCancelled, isCurrent(), pending == nil, Self.isDigest(expectedSHA256) else { throw Failure.staleIntent }
        let text = try await send("protected-snapshot", 15)
        guard !text.contains("\r"), !text.contains("\t"), !text.dropLast().contains(where: { $0.isNewline }) else { throw Failure.invalidResponse }
        let snapshot = try fields(text)
        let currentKeys: Set<String> = ["protected_protocol", "recovery_pending", "source_sha256", "owner_token_sha256", "commit_receipt_protocol"]
        let legacyKeys = currentKeys.subtracting(["commit_receipt_protocol"]).union(["transaction_id"])
        // Current root healthy snapshots have no transaction_id. Accept the
        // previous six-field client contract only with an exact canonical UUID.
        guard Set(snapshot.keys) == currentKeys || Set(snapshot.keys) == currentKeys.union(["transaction_id"])
                || Set(snapshot.keys) == legacyKeys,
              text.dropLast().split(separator: " ", omittingEmptySubsequences: false).count == snapshot.count,
              snapshot["transaction_id"].map({ UUID(uuidString: $0)?.uuidString == $0 }) ?? true else { throw Failure.invalidResponse }
        guard !Task.isCancelled, isCurrent(), pending == nil else { throw Failure.staleIntent }
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false",
              snapshot["source_sha256"] == expectedSHA256,
              // Old protected snapshots predate receipt support. Their exact
              // canonical five-field/UUID contract can prove NORMAL admission,
              // not receipt support or terminal retirement on an old helper.
              snapshot["commit_receipt_protocol"] == "1" || Set(snapshot.keys) == legacyKeys,
              let owner = snapshot["owner_token_sha256"], Self.isDigest(owner) else { throw Failure.sourceMismatch }
        return owner
    }

    func replace(sourceSHA256: String, candidateSHA256: String, sourceOwnerTokenSHA256: String? = nil,
                 dependencies d: Dependencies) async throws -> Receipt {
        try current(d)
        var prepared: Transaction?
        if let persistence = d.persistence {
            try validatePersistence(persistence)
            if let stored = try loadIntent(persistence) {
                guard stored.transaction.source == sourceSHA256, stored.transaction.candidate == candidateSHA256,
                      stored.transaction.owner == sourceOwnerTokenSHA256,
                      pending == nil || pending?.id == stored.transaction.id else { throw Failure.recoveryPending }
                if stored.transaction.stageConsentPending == true {
                    guard d.stageConsent != nil, stored.receipt == nil,
                          !stored.transaction.commitResponseUncertain else { throw Failure.recoveryPending }
                    prepared = stored.transaction
                } else { pending = stored.transaction }
            } else if pending != nil || committed != nil {
                throw Failure.persistenceUnavailable
            }
            activePersistence = persistence
        } else if activePersistence != nil {
            throw Failure.persistenceUnavailable
        }
        if let pending {
            guard pending.source == sourceSHA256 else { throw Failure.recoveryPending }
            if pending.supportsCommitReceipt && pending.commitResponseUncertain {
                guard pending.candidate == candidateSHA256 else { throw Failure.recoveryPending }
                do { return try await confirmDurableCommit(pending, dependencies: d) }
                catch { try current(d) } // A denied proof is not permission to adopt.
            }
            try await recover(pending, dependencies: d)
            throw Failure.sourceRestored
        }
        let snapshot: [String: String]
        if let prepared {
            // Retry the exact original nonce/grant, not a fresh snapshot which
            // could silently authorize a different transaction after lost ACK.
            snapshot = ["protected_protocol": "1", "recovery_pending": "false",
                "source_sha256": prepared.source, "transaction_id": prepared.id,
                "owner_token_sha256": prepared.owner, "commit_receipt_protocol": "1"]
        } else { snapshot = try fields(await d.send("protected-snapshot", 15)) }
        try current(d)
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false" else {
            throw Failure.recoveryPending
        }
        guard snapshot["source_sha256"] == sourceSHA256, sourceSHA256 != candidateSHA256 else {
            throw Failure.sourceMismatch
        }
        // TODO(protected-current-snapshot-intent): the current root healthy
        // snapshot has five fields and no transaction_id. The first NEW cutover
        // must allocate/persist its own one-use intent only after exact current
        // source/owner proof; never reconstruct an existing/missing old nonce.
        // This initial-cutover path still fails closed until that contract and
        // actual root/client cross-contract fixtures are verified offline.
        guard let id = snapshot["transaction_id"], UUID(uuidString: id)?.uuidString == id,
              let owner = snapshot["owner_token_sha256"], Self.isDigest(owner),
              Self.isDigest(sourceSHA256), Self.isDigest(candidateSHA256) else { throw Failure.invalidResponse }
        if let expectedOwner = sourceOwnerTokenSHA256 {
            guard Self.isDigest(expectedOwner), owner == expectedOwner else { throw Failure.sourceMismatch }
        }
        var transaction = Transaction(id: id, source: sourceSHA256, candidate: candidateSHA256, owner: owner,
                                      supportsCommitReceipt: snapshot["commit_receipt_protocol"] == "1")
        transaction.stageConsentPending = prepared?.stageConsentPending ?? (d.stageConsent == nil ? nil : true)
        if d.stageConsent != nil { guard d.persistence != nil else { throw Failure.persistenceUnavailable } }
        if d.persistence != nil {
            guard transaction.supportsCommitReceipt, sourceOwnerTokenSHA256 == owner else { throw Failure.persistenceUnavailable }
            try persistIntent(transaction, receipt: nil)
        }
        try current(d)
        try d.stageCandidate()
        try current(d)
        if transaction.stageConsentPending == true {
            guard let consent = d.stageConsent, let persistence = d.persistence,
                  let data = try persistence.load() else { throw Failure.persistenceUnavailable }
            let intent = try Self.restartIntent(data)
            // The callback persists exact private material+capability before
            // authorize-stage and checks the strict ACK. No catch/fallback.
            try await consent(intent, d.send)
            try current(d)
            transaction.stageConsentPending = false
            try persistIntent(transaction, receipt: nil)
            try current(d)
        }
        pending = transaction
        committed = nil
        do {
            let ready = try fields(await d.send("protected-replace " + transaction.metadata, 60), word: "ready")
            try current(d)
            guard ready["transaction_id"] == id, ready["candidate_sha256"] == candidateSHA256 else { throw Failure.invalidResponse }
            for _ in 0..<40 {
                try current(d)
                transaction.commitResponseUncertain = true
                pending = transaction
                try persistIntent(transaction, receipt: nil)
                let response = try await d.send("protected-commit " + transaction.metadata, 15)
                try current(d)
                if response == "error: protected replacement awaiting fresh handshake\n" {
                    transaction.commitResponseUncertain = false
                    pending = transaction
                    try persistIntent(transaction, receipt: nil)
                    try await d.wait()
                    continue
                }
                let committed = try fields(response, word: "committed")
                guard committed["transaction_id"] == id, committed["candidate_sha256"] == candidateSHA256,
                      let value = committed["latest_handshake"], let handshake = UInt64(value), handshake > 0 else {
                    throw Failure.invalidResponse
                }
                try current(d)
                pending = nil
                let receipt = Receipt(transactionID: id, candidateSHA256: candidateSHA256,
                                      latestHandshake: handshake, ownerTokenSHA256: owner)
                self.committed = (transaction, receipt)
                persistConfirmedIntent(transaction, receipt: receipt)
                return receipt
            }
            throw Failure.handshakeTimeout
        } catch {
            // Cancellation/account/device/selection changes never trigger a
            // stale rollback or another helper command. Keep recovery evidence.
            guard d.isCurrent(), !Task.isCancelled else { throw Failure.staleIntent }
            if transaction.supportsCommitReceipt && transaction.commitResponseUncertain {
                // A lost/malformed ACK may follow a REAL commit. Only the exact
                // authenticated durable receipt can resolve this ambiguity.
                do { return try await confirmDurableCommit(transaction, dependencies: d) }
                catch { try current(d) }
            }
            do { try await recover(transaction, dependencies: d) }
            catch { throw Failure.recoveryPending }
            throw Failure.sourceRestored
        }
    }

    /// Reconcile a post-commit cache failure without another replace, commit,
    /// recovery, config write, or DNS lookup. The receipt must originate from
    /// this coordinator and the authenticated helper must still own its exact
    /// candidate bytes. A cached UI status is not sufficient evidence.
    func revalidateCommitted(_ receipt: Receipt, isCurrent: () -> Bool,
        send: (String, Int) async throws -> String, persistence: Persistence? = nil) async throws {
        if let persistence {
            guard !Task.isCancelled, isCurrent(), pending == nil else { throw Failure.staleIntent }
            guard let stored = try loadIntent(persistence), matches(receipt, transaction: stored.transaction),
                  stored.receipt == nil || stored.receipt == receipt else { throw Failure.recoveryPending }
            // Disk metadata grants nothing. The exact authenticated root receipt
            // below is required even when the coordinator was reconstructed.
            let proof = try await durableCommitReceipt(stored.transaction, isCurrent: isCurrent, send: send)
            guard !Task.isCancelled, isCurrent(), pending == nil, proof == receipt,
                  try persistence.load() == encode(stored) else { throw Failure.staleIntent }
            activePersistence = persistence
            committed = (stored.transaction, receipt)
            return
        } else if activePersistence != nil { throw Failure.persistenceUnavailable }
        guard !Task.isCancelled, isCurrent(), pending == nil,
              let committed, committed.receipt == receipt else { throw Failure.staleIntent }
        if committed.transaction.supportsCommitReceipt {
            let proof = try await durableCommitReceipt(committed.transaction, isCurrent: isCurrent, send: send)
            guard pending == nil, self.committed?.receipt == receipt, proof == receipt else { throw Failure.staleIntent }
            return
        }
        let snapshot = try fields(await send("protected-snapshot", 15))
        guard !Task.isCancelled, isCurrent(), pending == nil,
              self.committed?.receipt == receipt else { throw Failure.staleIntent }
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false",
              snapshot["source_sha256"] == receipt.candidateSHA256,
              snapshot["owner_token_sha256"] == committed.transaction.owner else {
            throw Failure.recoveryPending
        }
    }

    private func durableCommitReceipt(_ transaction: Transaction, isCurrent: () -> Bool,
        send: (String, Int) async throws -> String) async throws -> Receipt {
        guard !Task.isCancelled, isCurrent() else { throw Failure.staleIntent }
        let proof = try fields(await send("protected-receipt " + transaction.metadata, 15), word: "committed")
        guard !Task.isCancelled, isCurrent() else { throw Failure.staleIntent }
        guard Set(proof.keys) == ["commit_receipt_protocol", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "latest_handshake"],
              proof["commit_receipt_protocol"] == "1", proof["transaction_id"] == transaction.id,
              proof["source_sha256"] == transaction.source, proof["candidate_sha256"] == transaction.candidate,
              proof["owner_token_sha256"] == transaction.owner,
              let value = proof["latest_handshake"], let handshake = UInt64(value), handshake > 0,
              String(handshake) == value, handshake <= UInt64(max(0, Date().timeIntervalSince1970)) + 1 else {
            throw Failure.invalidResponse
        }
        return .init(transactionID: transaction.id, candidateSHA256: transaction.candidate,
                     latestHandshake: handshake, ownerTokenSHA256: transaction.owner)
    }

    private func confirmDurableCommit(_ transaction: Transaction, dependencies d: Dependencies) async throws -> Receipt {
        let receipt = try await durableCommitReceipt(transaction, isCurrent: d.isCurrent, send: d.send)
        try current(d)
        guard pending?.id == transaction.id, pending?.source == transaction.source,
              pending?.candidate == transaction.candidate, pending?.owner == transaction.owner else { throw Failure.staleIntent }
        pending = nil
        committed = (transaction, receipt)
        persistConfirmedIntent(transaction, receipt: receipt)
        return receipt
    }

    /// Called only after the exact confirmed candidate was saved to the app cache.
    /// Removal failure retains evidence and the receipt for a cache-only retry.
    func completeCommitted(_ receipt: Receipt, persistence: Persistence) throws {
        guard !Task.isCancelled, pending == nil, committed?.receipt == receipt,
              let stored = try loadIntent(persistence), matches(receipt, transaction: stored.transaction),
              stored.receipt == nil || stored.receipt == receipt else { throw Failure.recoveryPending }
        let bytes = try encode(stored)
        try persistence.remove(bytes)
        guard try persistence.load() == nil else { throw Failure.persistenceUnavailable }
        committed = nil
        activePersistence = nil
        hasUnconfirmedDurableWrite = false
    }

    private func matches(_ receipt: Receipt, transaction: Transaction) -> Bool {
        receipt.transactionID == transaction.id && receipt.candidateSHA256 == transaction.candidate
            && receipt.ownerTokenSHA256 == transaction.owner && receipt.latestHandshake > 0
    }

    private func validatePersistence(_ persistence: Persistence) throws {
        guard Self.isDigest(persistence.scopeFingerprint), persistence.generation >= 0,
              persistence.processInstanceID == Self.processInstanceID else { throw Failure.staleIntent }
        if let activePersistence {
            guard activePersistence.scopeFingerprint == persistence.scopeFingerprint,
                  activePersistence.processInstanceID == persistence.processInstanceID,
                  activePersistence.generation == persistence.generation else { throw Failure.staleIntent }
        }
    }

    private func encode(_ value: StoredIntent) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(10)
        guard data.count <= 16_384 else { throw Failure.persistenceUnavailable }
        return data
    }

    static func requireSamePersistentIdentity(_ existing: Data, _ replacement: Data) throws {
        guard existing.count <= 16_384, replacement.count <= 16_384,
              let old = try? JSONDecoder().decode(StoredIntent.self, from: existing),
              let new = try? JSONDecoder().decode(StoredIntent.self, from: replacement),
              old.schema == 1, new.schema == 1, old.scopeFingerprint == new.scopeFingerprint,
              old.processInstanceID == new.processInstanceID, old.generation == new.generation,
              old.transaction.id == new.transaction.id, old.transaction.source == new.transaction.source,
              old.transaction.candidate == new.transaction.candidate, old.transaction.owner == new.transaction.owner,
              old.transaction.supportsCommitReceipt == new.transaction.supportsCommitReceipt,
              old.transaction.stageConsentPending == nil ? new.transaction.stageConsentPending == nil
                  : (new.transaction.stageConsentPending != nil
                     && !(old.transaction.stageConsentPending == false && new.transaction.stageConsentPending == true)),
              old.receipt == nil || old.receipt == new.receipt else { throw Failure.persistenceUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = try encoder.encode(old); canonical.append(10)
        guard canonical == existing else { throw Failure.persistenceUnavailable }
    }

    static func requireValidPersistentPayload(_ data: Data, scopeFingerprint: String, generation: Int) throws {
        let persistence = Persistence(scopeFingerprint: scopeFingerprint, processInstanceID: processInstanceID,
            generation: generation, load: { data }, save: { _ in throw Failure.persistenceUnavailable },
            remove: { _ in throw Failure.persistenceUnavailable })
        guard try NativeProtectedReplacementCoordinator().loadIntent(persistence) != nil else { throw Failure.persistenceUnavailable }
    }

    /// Cancellation ACK authorizes only exact private cleanup, not admission.
    static func requireUnconsumedStageIntent(_ data: Data, original: RestartIntent) throws {
        try requireValidPersistentPayload(data, scopeFingerprint: original.scopeFingerprint, generation: original.generation)
        guard try restartIntent(data) == original,
              let stored = try? JSONDecoder().decode(StoredIntent.self, from: data),
              stored.transaction.stageConsentPending == true,
              !stored.transaction.commitResponseUncertain, stored.receipt == nil else { throw Failure.recoveryPending }
    }

    /// Strict cross-process inspection only. Ordinary load/save remain bound to
    /// the current process and scope; only the separate proved restart can rebind.
    private static func restartValue(_ data: Data) throws -> StoredIntent {
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(StoredIntent.self, from: data),
              value.schema == 1, value.transaction.supportsCommitReceipt else { throw Failure.persistenceUnavailable }
        let tuple = restartTuple(value)
        guard tuple.isValid, value.receipt.map({ $0.transactionID == tuple.transactionID
            && $0.candidateSHA256 == tuple.candidateSHA256 && $0.ownerTokenSHA256 == tuple.ownerTokenSHA256
            && $0.latestHandshake > 0 && $0.latestHandshake <= UInt64(max(0, Date().timeIntervalSince1970)) + 1
            && value.transaction.commitResponseUncertain }) ?? true,
              try NativeProtectedReplacementCoordinator().encode(value) == data else { throw Failure.persistenceUnavailable }
        return value
    }
    private static func restartTuple(_ value: StoredIntent) -> RestartIntent {
        .init(transactionID: value.transaction.id, sourceSHA256: value.transaction.source,
            candidateSHA256: value.transaction.candidate, ownerTokenSHA256: value.transaction.owner,
            scopeFingerprint: value.scopeFingerprint, processInstanceID: value.processInstanceID, generation: value.generation)
    }
    static func restartIntent(_ data: Data) throws -> RestartIntent { restartTuple(try restartValue(data)) }
    /// Both pre-send and conservatively consumed opt-in nonces require distinct
    /// purpose custody. Absence of that file never changes the nonce's protocol.
    static func stageConsentExpected(_ data: Data, original: RestartIntent) throws -> Bool {
        let value = try restartValue(data)
        guard restartTuple(value) == original else { throw Failure.persistenceUnavailable }
        return value.transaction.stageConsentPending != nil
    }
    /// Metadata only. The existing current-process loader and fresh root proof
    /// must authenticate this saved receipt before any completion/admission.
    static func restartReceiptMetadata(_ data: Data) throws -> Receipt? { try restartValue(data).receipt }

    /// Exact terminal private cleanup only; a root proof is independently
    /// obtained by the caller. This never rebinds or creates a nonce/admission.
    static func requireTerminalPersistentPayload(_ data: Data, intent: RestartIntent, receipt: Receipt?) throws {
        let value = try restartValue(data)
        guard restartTuple(value) == intent, value.transaction.stageConsentPending != true else { throw Failure.recoveryPending }
        if let receipt {
            guard receipt.transactionID == intent.transactionID, receipt.candidateSHA256 == intent.candidateSHA256,
                  receipt.ownerTokenSHA256 == intent.ownerTokenSHA256, receipt.latestHandshake > 0,
                  value.receipt == nil || value.receipt == receipt else { throw Failure.recoveryPending }
        } else { guard value.receipt == nil else { throw Failure.recoveryPending } }
    }

    /// Private in-memory completion after fresh root proof and exact durable
    /// retirement. It cannot clear an unrelated pending/committed operation.
    func completePrivateRetirement(_ intent: RestartIntent, receipt: Receipt?) throws {
        guard !Task.isCancelled, pending == nil else { throw Failure.recoveryPending }
        if let committed {
            guard let receipt, committed.receipt == receipt, committed.transaction.id == intent.transactionID,
                  committed.transaction.source == intent.sourceSHA256, committed.transaction.candidate == intent.candidateSHA256,
                  committed.transaction.owner == intent.ownerTokenSHA256 else { throw Failure.recoveryPending }
        }
        if let activePersistence {
            guard activePersistence.scopeFingerprint == intent.scopeFingerprint,
                  activePersistence.generation == intent.generation, activePersistence.processInstanceID == intent.processInstanceID else { throw Failure.staleIntent }
        }
        committed = nil; activePersistence = nil; hasUnconfirmedDurableWrite = false
    }

    /// Called only with a fresh authenticated post-transfer receipt and reverified
    /// signed/current material. The random new-owner digest + transaction bind one
    /// adoption; no invented nonce, handshake, generation or config is permitted.
    static func reboundRestartIntent(_ existing: Data, original: RestartIntent, receipt: Receipt,
        scopeFingerprint: String) throws -> Data {
        let value = try restartValue(existing)
        guard original.isValid, original.processInstanceID != processInstanceID, isDigest(scopeFingerprint),
              receipt.transactionID == original.transactionID, receipt.candidateSHA256 == original.candidateSHA256,
              isDigest(receipt.ownerTokenSHA256), receipt.ownerTokenSHA256 != original.ownerTokenSHA256,
              receipt.latestHandshake > 0, receipt.latestHandshake <= UInt64(max(0, Date().timeIntervalSince1970)) + 1 else {
            throw Failure.persistenceUnavailable
        }
        let rebound = RestartIntent(transactionID: original.transactionID, sourceSHA256: original.sourceSHA256,
            candidateSHA256: original.candidateSHA256, ownerTokenSHA256: receipt.ownerTokenSHA256,
            scopeFingerprint: scopeFingerprint, processInstanceID: processInstanceID, generation: original.generation)
        let tuple = restartTuple(value)
        if tuple == rebound {
            guard value.receipt == receipt, value.transaction.commitResponseUncertain else { throw Failure.persistenceUnavailable }
            return existing // exact same process/adoption retry after a lost file ACK
        }
        guard tuple == original, value.receipt.map({ $0.latestHandshake == receipt.latestHandshake }) ?? true else {
            throw Failure.persistenceUnavailable
        }
        let transaction = Transaction(id: original.transactionID, source: original.sourceSHA256,
            candidate: original.candidateSHA256, owner: receipt.ownerTokenSHA256,
            supportsCommitReceipt: true, commitResponseUncertain: true)
        let data = try NativeProtectedReplacementCoordinator().encode(StoredIntent(schema: 1,
            scopeFingerprint: scopeFingerprint, processInstanceID: processInstanceID, generation: original.generation,
            transaction: transaction, receipt: receipt))
        try requireValidPersistentPayload(data, scopeFingerprint: scopeFingerprint, generation: original.generation)
        return data
    }

    private func loadIntent(_ persistence: Persistence) throws -> StoredIntent? {
        try validatePersistence(persistence)
        guard let bytes = try persistence.load() else { return nil }
        guard bytes.count <= 16_384, let value = try? JSONDecoder().decode(StoredIntent.self, from: bytes),
              value.schema == 1, value.scopeFingerprint == persistence.scopeFingerprint,
              value.processInstanceID == persistence.processInstanceID, value.generation == persistence.generation,
              value.transaction.supportsCommitReceipt,
              UUID(uuidString: value.transaction.id)?.uuidString == value.transaction.id,
              Self.isDigest(value.transaction.source), Self.isDigest(value.transaction.candidate), Self.isDigest(value.transaction.owner),
              value.transaction.source != value.transaction.candidate,
              value.transaction.stageConsentPending != true || (!value.transaction.commitResponseUncertain && value.receipt == nil),
              value.receipt.map({ matches($0, transaction: value.transaction) && value.transaction.commitResponseUncertain
                  && $0.latestHandshake <= UInt64(max(0, Date().timeIntervalSince1970)) + 1 }) ?? true,
              (try? encode(value)) == bytes else { throw Failure.persistenceUnavailable }
        return value
    }

    private func persistIntent(_ transaction: Transaction, receipt: Receipt?) throws {
        guard let persistence = activePersistence else { return }
        let value = StoredIntent(schema: 1, scopeFingerprint: persistence.scopeFingerprint,
            processInstanceID: persistence.processInstanceID, generation: persistence.generation, transaction: transaction, receipt: receipt)
        let data = try encode(value)
        try persistence.save(data)
        guard try persistence.load() == data else { throw Failure.persistenceUnavailable }
        hasUnconfirmedDurableWrite = false
    }

    private func persistConfirmedIntent(_ transaction: Transaction, receipt: Receipt) {
        // Never turn an observed physical commit into a fake rollback or retain
        // the old UI profile solely because an app metadata write failed. The
        // already durable pre-commit nonce still permits exact root proof retry.
        do { try persistIntent(transaction, receipt: receipt) }
        catch { hasUnconfirmedDurableWrite = true }
    }

    private func recover(_ transaction: Transaction, dependencies d: Dependencies) async throws {
        try current(d)
        let snapshot = try fields(await d.send("protected-snapshot", 15))
        try current(d)
        guard snapshot["protected_protocol"] == "1", snapshot["owner_token_sha256"] == transaction.owner else {
            throw Failure.recoveryPending
        }
        if snapshot["recovery_pending"] == "true" {
            guard snapshot["transaction_id"] == transaction.id,
                  snapshot["source_sha256"] == transaction.source,
                  snapshot["candidate_sha256"] == transaction.candidate else { throw Failure.recoveryPending }
            let response = try fields(await d.send("protected-recover " + transaction.metadata, 60), word: "recovered")
            try current(d)
            guard response["transaction_id"] == transaction.id else { throw Failure.invalidResponse }
        } else {
            // A lost commit acknowledgement with the candidate already active
            // is not permission to claim rollback or promote an unproven receipt.
            guard snapshot["recovery_pending"] == "false", snapshot["source_sha256"] == transaction.source else {
                throw Failure.recoveryPending
            }
        }
        try current(d)
        try d.restoreSource()
        if let persistence = activePersistence {
            guard let stored = try loadIntent(persistence), stored.transaction.id == transaction.id else { throw Failure.persistenceUnavailable }
            try persistence.remove(try encode(stored))
            guard try persistence.load() == nil else { throw Failure.persistenceUnavailable }
            activePersistence = nil
        }
        pending = nil
    }

    private func current(_ d: Dependencies) throws {
        guard !Task.isCancelled, d.isCurrent() else { throw Failure.staleIntent }
    }

    nonisolated static func validDigest(_ text: String) -> Bool { isDigest(text) }

    nonisolated private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func fields(_ response: String, word: String? = nil) throws -> [String: String] {
        guard response.utf8.count <= 4096, response.hasSuffix("\n"), !response.contains("\0") else { throw Failure.invalidResponse }
        var parts = response.split(whereSeparator: \.isWhitespace)
        if let word {
            guard parts.first == Substring(word) else { throw Failure.invalidResponse }
            parts.removeFirst()
        }
        var result: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  result.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { throw Failure.invalidResponse }
        }
        return result
    }

    /// Separate receipt-nil rebind for an authenticated transferred JOURNAL.
    /// Ownership is not a commit. Preserve nonce/material/generation exactly.
    static func reboundJournalIntent(_ existing: Data, original: RestartIntent,
        ownership: JournalOwnership, scopeFingerprint: String) throws -> Data {
        let value = try restartValue(existing)
        guard original.isValid, original.processInstanceID != processInstanceID,
              isDigest(scopeFingerprint), ownership.transactionID == original.transactionID,
              ownership.sourceSHA256 == original.sourceSHA256, ownership.candidateSHA256 == original.candidateSHA256,
              isDigest(ownership.ownerTokenSHA256), ownership.ownerTokenSHA256 != original.ownerTokenSHA256,
              value.receipt == nil else { throw Failure.persistenceUnavailable }
        let new = RestartIntent(transactionID: original.transactionID, sourceSHA256: original.sourceSHA256,
            candidateSHA256: original.candidateSHA256, ownerTokenSHA256: ownership.ownerTokenSHA256,
            scopeFingerprint: scopeFingerprint, processInstanceID: processInstanceID, generation: original.generation)
        if restartTuple(value) == new {
            guard value.transaction.commitResponseUncertain else { throw Failure.persistenceUnavailable }; return existing
        }
        guard restartTuple(value) == original else { throw Failure.persistenceUnavailable }
        let transaction = Transaction(id: original.transactionID, source: original.sourceSHA256,
            candidate: original.candidateSHA256, owner: ownership.ownerTokenSHA256,
            supportsCommitReceipt: true, commitResponseUncertain: true)
        let data = try NativeProtectedReplacementCoordinator().encode(StoredIntent(schema: 1,
            scopeFingerprint: scopeFingerprint, processInstanceID: processInstanceID,
            generation: original.generation, transaction: transaction, receipt: nil))
        try requireValidPersistentPayload(data, scopeFingerprint: scopeFingerprint, generation: original.generation)
        return data
    }

}

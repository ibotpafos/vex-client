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
    }

    enum Failure: Error {
        case staleIntent, sourceMismatch, invalidResponse, recoveryPending, sourceRestored, handshakeTimeout
    }

    struct Receipt: Equatable {
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

    private struct Transaction {
        let id: String
        let source: String
        let candidate: String
        let owner: String
        var metadata: String {
            "transaction_id=\(id) source_sha256=\(source) candidate_sha256=\(candidate) owner_token_sha256=\(owner)"
        }
    }
    // TODO: Add explicitly authorized ownership transfer after an app-process
    // crash. Never adopt an old process's journal merely because its PID died;
    // restart/ownership-transfer acceptance requires the isolated runtime gate.
    private var pending: Transaction?
    private var committed: (transaction: Transaction, receipt: Receipt)?
    var hasPendingTransaction: Bool { pending != nil }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func verifyAdmittedSource(_ expectedSHA256: String, isCurrent: () -> Bool,
        send: (String, Int) async throws -> String) async throws -> String {
        guard !Task.isCancelled, isCurrent(), pending == nil, Self.isDigest(expectedSHA256) else { throw Failure.staleIntent }
        let snapshot = try fields(await send("protected-snapshot", 15))
        guard !Task.isCancelled, isCurrent(), pending == nil else { throw Failure.staleIntent }
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false",
              snapshot["source_sha256"] == expectedSHA256,
              let id = snapshot["transaction_id"], UUID(uuidString: id)?.uuidString == id,
              let owner = snapshot["owner_token_sha256"], Self.isDigest(owner) else { throw Failure.sourceMismatch }
        return owner
    }

    func replace(sourceSHA256: String, candidateSHA256: String, sourceOwnerTokenSHA256: String? = nil,
                 dependencies d: Dependencies) async throws -> Receipt {
        try current(d)
        if let pending {
            guard pending.source == sourceSHA256 else { throw Failure.recoveryPending }
            try await recover(pending, dependencies: d)
            throw Failure.sourceRestored
        }
        let snapshot = try fields(await d.send("protected-snapshot", 15))
        try current(d)
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false" else {
            throw Failure.recoveryPending
        }
        guard snapshot["source_sha256"] == sourceSHA256, sourceSHA256 != candidateSHA256 else {
            throw Failure.sourceMismatch
        }
        guard let id = snapshot["transaction_id"], UUID(uuidString: id)?.uuidString == id,
              let owner = snapshot["owner_token_sha256"], Self.isDigest(owner),
              Self.isDigest(sourceSHA256), Self.isDigest(candidateSHA256) else { throw Failure.invalidResponse }
        if let expectedOwner = sourceOwnerTokenSHA256 {
            guard Self.isDigest(expectedOwner), owner == expectedOwner else { throw Failure.sourceMismatch }
        }
        let transaction = Transaction(id: id, source: sourceSHA256, candidate: candidateSHA256, owner: owner)
        try current(d)
        try d.stageCandidate()
        try current(d)
        pending = transaction
        committed = nil
        do {
            let ready = try fields(await d.send("protected-replace " + transaction.metadata, 60), word: "ready")
            try current(d)
            guard ready["transaction_id"] == id, ready["candidate_sha256"] == candidateSHA256 else { throw Failure.invalidResponse }
            for _ in 0..<40 {
                try current(d)
                let response = try await d.send("protected-commit " + transaction.metadata, 15)
                try current(d)
                if response == "error: protected replacement awaiting fresh handshake\n" {
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
                return receipt
            }
            throw Failure.handshakeTimeout
        } catch {
            // Cancellation/account/device/selection changes never trigger a
            // stale rollback or another helper command. Keep recovery evidence.
            guard d.isCurrent(), !Task.isCancelled else { throw Failure.staleIntent }
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
        send: (String, Int) async throws -> String) async throws {
        guard !Task.isCancelled, isCurrent(), pending == nil,
              let committed, committed.receipt == receipt else { throw Failure.staleIntent }
        let snapshot = try fields(await send("protected-snapshot", 15))
        guard !Task.isCancelled, isCurrent(), pending == nil,
              self.committed?.receipt == receipt else { throw Failure.staleIntent }
        guard snapshot["protected_protocol"] == "1", snapshot["recovery_pending"] == "false",
              snapshot["source_sha256"] == receipt.candidateSHA256,
              snapshot["owner_token_sha256"] == committed.transaction.owner else {
            throw Failure.recoveryPending
        }
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
        pending = nil
    }

    private func current(_ d: Dependencies) throws {
        guard !Task.isCancelled, d.isCurrent() else { throw Failure.staleIntent }
    }

    private static func isDigest(_ text: String) -> Bool {
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
}

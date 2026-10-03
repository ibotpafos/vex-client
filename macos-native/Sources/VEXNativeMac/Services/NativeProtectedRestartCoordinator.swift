import Foundation

/// The only client ports are bounded private custody and authenticated socket
/// RPC. No installer, generic attach/connect/disconnect, DNS, API or ACK port.
@MainActor
final class NativeProtectedRestartCoordinator {
    enum Failure: LocalizedError {
        case staleIntent, unavailable, invalidResponse, recoveryPending
        var errorDescription: String? { "Защищённое восстановление не подтверждено. Обычное переподключение не выполнялось." }
    }
    struct Dependencies {
        let isCurrent: () -> Bool
        let validateMaterial: () throws -> Void
        let send: (String, Int) async throws -> String
        let store: NativeProtectedRestartStore
        let owner: NativePushPSKEventOwner
        let material: NativeProtectedRestartStore.Material
        var now: () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970)) }
        var generateCapability: () throws -> String = NativeProtectedRestartStore.randomCapability
    }
    private func current(_ d: Dependencies) throws {
        guard !Task.isCancelled, d.isCurrent(), try d.store.loadMaterial(owner: d.owner) == d.material else { throw Failure.staleIntent }
        try d.validateMaterial()
        guard !Task.isCancelled, d.isCurrent() else { throw Failure.staleIntent }
    }
    private func command(_ verb: String, capability: NativeProtectedRestartStore.Capability) -> String {
        let t = capability.intent
        return verb + " transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(t.ownerTokenSHA256) restart_capability=\(capability.value)"
    }
    /// Root/transport errors may reflect old clients' inputs. Never propagate
    /// their text to LocalizedError, diagnostics or UI, including raw capability.
    private func send(_ command: String, _ d: Dependencies) async throws -> String {
        do { return try await d.send(command, 15) } catch { throw Failure.unavailable }
    }
    private func fields(_ text: String, word: String, keys: Set<String>) throws -> [String: String] {
        guard text.utf8.count <= 4096, text.hasSuffix("\n"), !text.utf8.contains(0),
              !text.dropLast().contains(where: { $0.isNewline }), !text.contains("\r"), !text.contains("\t") else { throw Failure.invalidResponse }
        var parts = text.dropLast().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.first == Substring(word) else { throw Failure.invalidResponse }; parts.removeFirst()
        var result: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  result.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { throw Failure.invalidResponse }
        }
        guard Set(result.keys) == keys else { throw Failure.invalidResponse }; return result
    }
    // TODO(pre-stage-consent): close the crash window before candidate staging
    // with a separate compatible root-private consent lifecycle. The existing
    // owner-transfer fence blocks replace and requires a journal/receipt; it
    // cannot authorize a pre-stage mutation. This pass verifies continuation of
    // an already authorized journal only, not this unfinished root contract.
    func authorize(_ d: Dependencies) async throws -> UInt64 {
        try current(d)
        guard d.material.intent.processInstanceID == NativeProtectedReplacementCoordinator.processInstanceID else { throw Failure.staleIntent }
        let capability = try d.store.capability(owner: d.owner, material: d.material, now: d.now(), generate: d.generateCapability)
        try current(d); try d.store.live(capability, now: d.now())
        let reply = try fields(await send(command("protected-authorize-restart", capability: capability), d),
            word: "restart-authorized", keys: ["transaction_id", "expires_at"])
        try current(d); try d.store.live(capability, now: d.now())
        guard reply["transaction_id"] == capability.intent.transactionID, let raw = reply["expires_at"],
              let expiry = UInt64(raw), String(expiry) == raw, expiry >= capability.expiresAt,
              expiry <= d.now() + 120 else { throw Failure.invalidResponse }
        return capability.expiresAt // never extend the earlier local custody window
    }
    func cancel(_ d: Dependencies) async throws {
        try current(d)
        guard d.material.intent.processInstanceID == NativeProtectedReplacementCoordinator.processInstanceID,
              let capability = try d.store.loadCapability(owner: d.owner, material: d.material) else { throw Failure.staleIntent }
        let reply = try fields(await send(command("protected-cancel-restart", capability: capability), d),
            word: "restart-cancelled", keys: ["transaction_id"])
        try current(d)
        guard reply["transaction_id"] == capability.intent.transactionID else { throw Failure.invalidResponse }
        try d.store.removeCapability(owner: d.owner, expected: capability)
    }
    /// Transfer itself is NOT a receipt. An ephemeral new-owner tuple requests
    /// root proof before any app binding is changed. Caller must authenticate
    /// that same receipt AGAIN after its narrow private persistence rebind.
    func adopt(_ d: Dependencies) async throws -> NativeProtectedReplacementCoordinator.Receipt {
        try current(d)
        guard d.material.intent.processInstanceID != NativeProtectedReplacementCoordinator.processInstanceID,
              let capability = try d.store.loadCapability(owner: d.owner, material: d.material) else { throw Failure.staleIntent }
        try d.store.live(capability, now: d.now())
        let reply = try fields(await send(command("protected-adopt-restart", capability: capability), d),
            word: "owner-transferred", keys: ["restart_protocol", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "evidence_kind"])
        try current(d); try d.store.live(capability, now: d.now())
        let t = capability.intent
        guard reply["restart_protocol"] == "1", reply["transaction_id"] == t.transactionID,
              reply["source_sha256"] == t.sourceSHA256, reply["candidate_sha256"] == t.candidateSHA256,
              let owner = reply["owner_token_sha256"], NativeProtectedReplacementCoordinator.validDigest(owner),
              owner != t.ownerTokenSHA256, ["journal", "receipt"].contains(reply["evidence_kind"] ?? "") else { throw Failure.invalidResponse }
        // Receipt recovery remains separate from explicit journal restore/resume.
        // Never promote a journal from transfer ACK, cached status or dead PID.
        guard reply["evidence_kind"] == "receipt" else { throw Failure.recoveryPending }
        let metadata = " transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(owner)"
        let proof = try fields(await send("protected-receipt" + metadata, d), word: "committed",
            keys: ["commit_receipt_protocol", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "latest_handshake"])
        try current(d); try d.store.live(capability, now: d.now())
        guard proof["commit_receipt_protocol"] == "1", proof["transaction_id"] == t.transactionID,
              proof["source_sha256"] == t.sourceSHA256, proof["candidate_sha256"] == t.candidateSHA256,
              proof["owner_token_sha256"] == owner, let raw = proof["latest_handshake"], let handshake = UInt64(raw),
              handshake > 0, String(handshake) == raw, handshake <= d.now() + 1 else { throw Failure.invalidResponse }
        return .init(transactionID: t.transactionID, candidateSHA256: t.candidateSHA256,
            latestHandshake: handshake, ownerTokenSHA256: owner)
    }

    /// Ownership/journal evidence is not a Receipt, admission or commit.
    typealias JournalOwnership = NativeProtectedReplacementCoordinator.JournalOwnership
    private func metadata(_ t: NativeProtectedReplacementCoordinator.RestartIntent) -> String {
        " transaction_id=\(t.transactionID) source_sha256=\(t.sourceSHA256) candidate_sha256=\(t.candidateSHA256) owner_token_sha256=\(t.ownerTokenSHA256)"
    }
    private func snapshot(_ text: String, _ t: NativeProtectedReplacementCoordinator.RestartIntent) throws -> Bool {
        let pending = text.contains(" recovery_pending=true ")
        let keys: Set<String> = pending
            ? ["protected_protocol", "recovery_pending", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "commit_receipt_protocol"]
            : ["protected_protocol", "recovery_pending", "source_sha256", "owner_token_sha256", "commit_receipt_protocol"]
        let value = try fields("snapshot " + text, word: "snapshot", keys: keys)
        guard value["protected_protocol"] == "1", value["commit_receipt_protocol"] == "1",
              value["owner_token_sha256"] == t.ownerTokenSHA256,
              value["recovery_pending"] == (pending ? "true" : "false") else { throw Failure.invalidResponse }
        if pending {
            guard value["transaction_id"] == t.transactionID, value["source_sha256"] == t.sourceSHA256,
                  value["candidate_sha256"] == t.candidateSHA256 else { throw Failure.invalidResponse }
        } else {
            guard value["source_sha256"] == t.sourceSHA256 || value["source_sha256"] == t.candidateSHA256 else { throw Failure.invalidResponse }
        }
        return pending
    }
    private func healthySnapshot(_ text: String, _ t: NativeProtectedReplacementCoordinator.RestartIntent, hash: String) throws {
        guard try !snapshot(text, t) else { throw Failure.recoveryPending }
        let value = try fields("snapshot " + text, word: "snapshot", keys:
            ["protected_protocol", "recovery_pending", "source_sha256", "owner_token_sha256", "commit_receipt_protocol"])
        guard value["source_sha256"] == hash else { throw Failure.recoveryPending }
    }
    func transferJournal(_ d: Dependencies) async throws -> JournalOwnership {
        try current(d)
        guard d.material.intent.processInstanceID != NativeProtectedReplacementCoordinator.processInstanceID,
              let cap = try d.store.loadCapability(owner: d.owner, material: d.material) else { throw Failure.staleIntent }
        try d.store.live(cap, now: d.now())
        let response = try fields(await send(command("protected-adopt-restart", capability: cap), d), word: "owner-transferred",
            keys: ["restart_protocol", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "evidence_kind"])
        try current(d); try d.store.live(cap, now: d.now())
        let old = d.material.intent
        guard response["restart_protocol"] == "1", response["evidence_kind"] == "journal",
              response["transaction_id"] == old.transactionID, response["source_sha256"] == old.sourceSHA256,
              response["candidate_sha256"] == old.candidateSHA256,
              let owner = response["owner_token_sha256"], NativeProtectedReplacementCoordinator.validDigest(owner),
              owner != old.ownerTokenSHA256 else { throw Failure.invalidResponse }
        let tuple = NativeProtectedReplacementCoordinator.RestartIntent(transactionID: old.transactionID,
            sourceSHA256: old.sourceSHA256, candidateSHA256: old.candidateSHA256, ownerTokenSHA256: owner,
            scopeFingerprint: old.scopeFingerprint, processInstanceID: old.processInstanceID, generation: old.generation)
        let proof = try await send("protected-snapshot", d)
        try current(d); try d.store.live(cap, now: d.now())
        guard try snapshot(proof, tuple) else { throw Failure.recoveryPending }
        return .init(transactionID: old.transactionID, sourceSHA256: old.sourceSHA256,
                     candidateSHA256: old.candidateSHA256, ownerTokenSHA256: owner)
    }
    private func currentJournal(_ t: NativeProtectedReplacementCoordinator.RestartIntent,
        persistence p: NativeProtectedReplacementCoordinator.Persistence, dependencies d: Dependencies) throws -> Data {
        try current(d)
        let original = d.material.intent
        guard t.isValid, t.processInstanceID == NativeProtectedReplacementCoordinator.processInstanceID,
              p.processInstanceID == t.processInstanceID, p.scopeFingerprint == t.scopeFingerprint, p.generation == t.generation,
              t.transactionID == original.transactionID, t.sourceSHA256 == original.sourceSHA256,
              t.candidateSHA256 == original.candidateSHA256, t.generation == original.generation,
              t.ownerTokenSHA256 != original.ownerTokenSHA256,
              let data = try p.load() else { throw Failure.staleIntent }
        try NativeProtectedReplacementCoordinator.requireValidPersistentPayload(data,
            scopeFingerprint: p.scopeFingerprint, generation: p.generation)
        guard try NativeProtectedReplacementCoordinator.restartIntent(data) == t,
              try NativeProtectedReplacementCoordinator.restartReceiptMetadata(data) == nil else { throw Failure.recoveryPending }
        try current(d); return data
    }
    private func journalReceipt(_ t: NativeProtectedReplacementCoordinator.RestartIntent, _ d: Dependencies) async throws -> NativeProtectedReplacementCoordinator.Receipt {
        let proof = try fields(await send("protected-receipt" + metadata(t), d), word: "committed", keys:
            ["commit_receipt_protocol", "transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256", "latest_handshake"])
        try current(d)
        guard proof["commit_receipt_protocol"] == "1", proof["transaction_id"] == t.transactionID,
              proof["source_sha256"] == t.sourceSHA256, proof["candidate_sha256"] == t.candidateSHA256,
              proof["owner_token_sha256"] == t.ownerTokenSHA256,
              let raw = proof["latest_handshake"], let handshake = UInt64(raw), String(handshake) == raw,
              handshake > 0, handshake <= d.now() + 1 else { throw Failure.invalidResponse }
        return .init(transactionID: t.transactionID, candidateSHA256: t.candidateSHA256,
                     latestHandshake: handshake, ownerTokenSHA256: t.ownerTokenSHA256)
    }
    /// Explicit candidate continuation only. Root enforces phase/health/fresh
    /// handshake floor. An ACK or journal snapshot never becomes a Receipt.
    func resumeJournal(_ t: NativeProtectedReplacementCoordinator.RestartIntent,
        persistence p: NativeProtectedReplacementCoordinator.Persistence, dependencies d: Dependencies,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 500_000_000) }) async throws -> NativeProtectedReplacementCoordinator.Receipt {
        _ = try currentJournal(t, persistence: p, dependencies: d)
        let state = try await send("protected-snapshot", d)
        _ = try currentJournal(t, persistence: p, dependencies: d)
        if try !snapshot(state, t) {
            try healthySnapshot(state, t, hash: t.candidateSHA256)
            let proof = try await journalReceipt(t, d)
            _ = try currentJournal(t, persistence: p, dependencies: d); return proof
        }
        for _ in 0..<40 {
            _ = try currentJournal(t, persistence: p, dependencies: d)
            let response = try await send("protected-commit" + metadata(t), d)
            _ = try currentJournal(t, persistence: p, dependencies: d)
            if response == "error: protected replacement awaiting fresh handshake\n" {
                try await wait(); continue
            }
            let fields = try fields(response, word: "committed", keys: ["transaction_id", "candidate_sha256", "latest_handshake"])
            guard fields["transaction_id"] == t.transactionID, fields["candidate_sha256"] == t.candidateSHA256,
                  let raw = fields["latest_handshake"], let handshake = UInt64(raw), String(handshake) == raw,
                  handshake > 0, handshake <= d.now() + 1 else { throw Failure.invalidResponse }
            let proof = try await journalReceipt(t, d)
            _ = try currentJournal(t, persistence: p, dependencies: d)
            guard proof.latestHandshake == handshake else { throw Failure.invalidResponse }; return proof
        }
        throw Failure.recoveryPending
    }
    /// Exact source restoration is a display/status result, NEVER admission.
    /// Fence is durable BEFORE root recovery. Lost ACK does not replay recovery;
    /// a later explicit retry proves the already healthy exact source twice.
    func restoreJournal(_ t: NativeProtectedReplacementCoordinator.RestartIntent,
        persistence p: NativeProtectedReplacementCoordinator.Persistence, dependencies d: Dependencies) async throws {
        _ = try currentJournal(t, persistence: p, dependencies: d)
        try d.store.markSourceRestoration(owner: d.owner, material: d.material, journalIntent: t)
        _ = try currentJournal(t, persistence: p, dependencies: d)
        let state = try await send("protected-snapshot", d)
        _ = try currentJournal(t, persistence: p, dependencies: d)
        if try snapshot(state, t) {
            let response = try fields(await send("protected-recover" + metadata(t), d), word: "recovered", keys: ["transaction_id"])
            _ = try currentJournal(t, persistence: p, dependencies: d)
            guard response["transaction_id"] == t.transactionID else { throw Failure.invalidResponse }
        } else { try healthySnapshot(state, t, hash: t.sourceSHA256) }
        for _ in 0..<2 {
            let proof = try await send("protected-snapshot", d)
            _ = try currentJournal(t, persistence: p, dependencies: d)
            try healthySnapshot(proof, t, hash: t.sourceSHA256)
        }
    }

}

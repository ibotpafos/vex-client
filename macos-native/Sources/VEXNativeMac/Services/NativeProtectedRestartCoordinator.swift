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
        // TODO: Journal-source/candidate continuation after authorized transfer
        // needs its own explicit protected restore/resume gate. Never promote a
        // journal from transfer acknowledgement, cached status or dead PID.
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
}

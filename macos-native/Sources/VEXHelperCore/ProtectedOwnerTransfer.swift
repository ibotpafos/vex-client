import Foundation
import Security

/// Explicit restart consent, not a reconnect or a commit proof. The caller
/// generates a 256-bit capability, keeps it in owned private storage, and sends
/// it only over the authenticated socket. Never log this request.
public struct ProtectedOwnerTransferRequest: Equatable, Sendable {
    public let replacement: ProtectedReplacementRequest
    public let capability: String

    public init(metadata: [String]) throws {
        let capabilities = metadata.filter { $0.hasPrefix("restart_capability=") }
        guard capabilities.count == 1, metadata.count == 5,
              let value = capabilities.first?.dropFirst("restart_capability=".count),
              Self.isDigest(String(value)) else {
            throw HelperError.protocolViolation("invalid protected restart metadata")
        }
        do {
            replacement = try ProtectedReplacementRequest(metadata: metadata.filter { !$0.hasPrefix("restart_capability=") })
        } catch {
            throw HelperError.protocolViolation("invalid protected restart metadata")
        }
        capability = String(value)
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public protocol ProtectedOwnerTransferControlling: Sendable {
    func authorizeProtectedRestart(request: ProtectedOwnerTransferRequest, uid: UInt32,
        validateOwner: () throws -> OwnerSession) throws -> String
    func adoptProtectedRestart(request: ProtectedOwnerTransferRequest, uid: UInt32,
        validatePeer: () throws -> OwnerSession, validatePreviousIdentity: (OwnerSession) throws -> Void) throws -> String
    func cancelProtectedRestart(request: ProtectedOwnerTransferRequest, uid: UInt32,
        validateOwner: () throws -> OwnerSession) throws -> String
}

/// Root-private write-ahead authority. No config/key/customer data or raw
/// restart capability is duplicated here. Full owner tokens are confined to
/// this root-private store, just as in owner.state and the recovery journal.
struct ProtectedOwnerTransferRecord: Codable {
    let schemaVersion: Int
    var phase: String
    let transactionID: String
    let sourceSHA256: String
    let candidateSHA256: String
    let capabilitySHA256: String
    let uid: UInt32
    let issuedAt: UInt64
    let expiresAt: UInt64
    let kind: String
    let oldOwner: String
    var newOwner: String?
    let session: String
    let evidenceSHA256: String
    let activeSHA256: String
    let dnsSHA256: String

    func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func validOwner(_ text: String) -> OwnerSession? {
        guard text.utf8.count <= 2_048, let owner = OwnerSession(payload: text), owner.pid > 1,
              !owner.token.isEmpty, owner.token.utf8.count <= 512,
              !owner.identity.isEmpty, owner.identity.utf8.count <= 1_024,
              !owner.token.contains(where: { $0.isWhitespace }),
              !owner.identity.contains(where: { $0.isNewline }),
              !text.utf8.contains(0), text == owner.payload else { return nil }
        return owner
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16_384,
              let r = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              r.schemaVersion == 1, ["authorized", "adopting", "transferred"].contains(r.phase),
              UUID(uuidString: r.transactionID)?.uuidString == r.transactionID,
              [r.sourceSHA256, r.candidateSHA256, r.capabilitySHA256, r.evidenceSHA256,
               r.activeSHA256, r.dnsSHA256].allSatisfy(ProtectedOwnerTransferRequest.isDigest),
              r.sourceSHA256 != r.candidateSHA256,
              [r.sourceSHA256, r.candidateSHA256].contains(r.activeSHA256),
              r.issuedAt > 0, r.issuedAt < 9_000_000_000, r.expiresAt == r.issuedAt + 120,
              ["journal", "receipt"].contains(r.kind), let old = validOwner(r.oldOwner),
              r.session.utf8.count <= 4_096, let session = HelperSession(payload: r.session),
              session.ownerPID == old.pid, session.payload == r.session,
              !r.session.utf8.contains(0),
              (r.phase == "authorized" ? r.newOwner == nil : r.newOwner.flatMap(validOwner).map {
                  $0.pid != old.pid && $0.token != old.token && $0.identity != old.identity
              } == true),
              (try? r.encoded()) == text else {
            throw HelperError.protocolViolation("invalid protected restart state")
        }
        return r
    }

    func matches(_ request: ProtectedOwnerTransferRequest, uid: UInt32) -> Bool {
        self.uid == uid && transactionID == request.replacement.transactionID
            && sourceSHA256 == request.replacement.sourceSHA256 && candidateSHA256 == request.replacement.candidateSHA256
            && ProtectedReplacementJournal.digest(OwnerSession(payload: oldOwner)!.token) == request.replacement.ownerTokenSHA256
            && capabilitySHA256 == ProtectedReplacementJournal.digest(request.capability)
    }
}

/// All work happens under the existing kernel operation lease. Dependencies
/// are FILES only: no TunnelControlling, PF, DNS, routes, process runner or API.
/// Multiple atomic writes are not a filesystem transaction. `adopting` is the
/// durable fence and exact-new-process retry authority for every partial write.
final class ProtectedOwnerTransferStore {
    private let files: HelperFileSystem
    private let paths: HelperPathsLayout
    private let clock: DateProviding
    private var recordPath: String { paths.helperDirectory + "/protected-owner-transfer.state" }
    private var journalPath: String { paths.helperDirectory + "/replacement-journal.state" }
    private var receiptPath: String { paths.helperDirectory + "/replacement-commit-receipt.state" }

    init(files: HelperFileSystem, paths: HelperPathsLayout, clock: DateProviding) {
        self.files = files; self.paths = paths; self.clock = clock
    }

    private func readRecord() throws -> ProtectedOwnerTransferRecord {
        guard files.pathPresence(at: recordPath) == .present else { throw denied() }
        return try ProtectedOwnerTransferRecord.decode(files.readPrivateText(at: recordPath, maxBytes: 16_384))
    }

    private func denied() -> HelperError { .ownerVerificationFailed("protected restart authorization denied") }

    private func liveWindow(_ r: ProtectedOwnerTransferRecord) throws {
        let now = clock.now.timeIntervalSince1970
        guard now.isFinite, now >= Double(r.issuedAt), now < Double(r.expiresAt) else { throw denied() }
    }

    private func write(_ text: String, path: String, maxBytes: Int) throws {
        try files.writeTextAtomically(text, to: path, mode: 0o600)
        guard try files.readPrivateText(at: path, maxBytes: maxBytes) == text else { throw denied() }
    }

    private func save(_ r: ProtectedOwnerTransferRecord) throws {
        let text = try r.encoded(); _ = try ProtectedOwnerTransferRecord.decode(text)
        try write(text, path: recordPath, maxBytes: 16_384)
    }

    private func replacement(_ r: ProtectedOwnerTransferRecord, owner: OwnerSession) throws -> ProtectedReplacementRequest {
        try ProtectedReplacementRequest(metadata: ["transaction_id=\(r.transactionID)", "source_sha256=\(r.sourceSHA256)",
            "candidate_sha256=\(r.candidateSHA256)", "owner_token_sha256=\(ProtectedReplacementJournal.digest(owner.token))"])
    }

    private func journal(_ original: ProtectedReplacementJournal, owner: OwnerSession) throws -> String {
        guard var source = HelperSession(payload: original.sourceSession) else { throw denied() }
        source.ownerPID = owner.pid
        var rebound = ProtectedReplacementJournal(ownerPID: owner.pid, sourceSession: source.payload,
            sourceConfig: original.sourceConfig, sourceSHA256: original.sourceSHA256,
            candidateConfig: original.candidateConfig, candidateSHA256: original.candidateSHA256,
            dnsBaseline: original.dnsBaseline, ownerSession: owner.payload)
        rebound.transactionID = original.transactionID; rebound.phase = original.phase
        rebound.handshakeNotBefore = original.handshakeNotBefore
        return try rebound.encoded()
    }

    /// Normalize ONLY the explicitly consented ownership fields. All other
    /// journal/receipt bytes, phase, handshake floor, material and DNS must still
    /// hash to the original authority, including across a partial-write retry.
    private func evidence(_ r: ProtectedOwnerTransferRecord, owner: OwnerSession) throws -> (String, String, Int) {
        let old = OwnerSession(payload: r.oldOwner)!
        let allowedOwners = [r.oldOwner, r.newOwner].compactMap { $0 }
        if r.kind == "journal" {
            guard files.pathPresence(at: journalPath) == .present else { throw denied() }
            let text = try files.readPrivateText(at: journalPath, maxBytes: 1_048_576)
            let original = try ProtectedReplacementJournal.decode(text)
            guard try original.encoded() == text, original.ownerSession.map(allowedOwners.contains) == true,
                  original.ownerSession.flatMap(OwnerSession.init(payload:))?.pid == original.ownerPID,
                  try replacement(r, owner: old).matches(ProtectedReplacementJournal.decode(journal(original, owner: old))),
                  ProtectedReplacementJournal.digest(try journal(original, owner: old)) == r.evidenceSHA256,
                  ProtectedReplacementJournal.digest(original.dnsBaseline) == r.dnsSHA256 else { throw denied() }
            return (journalPath, try journal(original, owner: owner), 1_048_576)
        }
        guard files.pathPresence(at: journalPath) == .absent else { throw denied() }
        let text = try files.readPrivateText(at: receiptPath, maxBytes: 16_384)
        let original = try ProtectedReplacementCommitReceipt.decode(text)
        let permitted = allowedOwners.compactMap(OwnerSession.init(payload:)).contains {
            original.ownerPID == $0.pid && original.ownerIdentity == $0.identity
                && original.ownerTokenSHA256 == ProtectedReplacementJournal.digest($0.token)
        }
        let normalized = ProtectedReplacementCommitReceipt(request: try replacement(r, owner: old), owner: old,
            latestHandshake: original.latestHandshake, handshakeNotBefore: original.handshakeNotBefore,
            sourceLatestHandshake: original.sourceLatestHandshake)
        guard permitted, original.transactionID == r.transactionID, original.sourceSHA256 == r.sourceSHA256,
              original.candidateSHA256 == r.candidateSHA256,
              ProtectedReplacementJournal.digest(try normalized.encoded()) == r.evidenceSHA256,
              r.activeSHA256 == r.candidateSHA256 else { throw denied() }
        let rebound = ProtectedReplacementCommitReceipt(request: try replacement(r, owner: owner), owner: owner,
            latestHandshake: original.latestHandshake, handshakeNotBefore: original.handshakeNotBefore,
            sourceLatestHandshake: original.sourceLatestHandshake)
        return (receiptPath, try rebound.encoded(), 16_384)
    }

    private func checkArtifacts(_ r: ProtectedOwnerTransferRecord) throws {
        let old = OwnerSession(payload: r.oldOwner)!
        let allowedOwners = [r.oldOwner, r.newOwner].compactMap { $0 }
        let ownerText = try files.readPrivateText(at: paths.ownerSessionPath, maxBytes: 2_048)
        guard allowedOwners.contains(ownerText) else { throw denied() }
        var next = HelperSession(payload: r.session)!
        if let text = r.newOwner { next.ownerPID = OwnerSession(payload: text)!.pid }
        let sessionText = try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096)
        guard [r.session, next.payload].contains(sessionText),
              try files.readPrivateText(at: paths.interfacePath, maxBytes: 128) == next.interfaceName + "\n",
              try files.readPrivateText(at: paths.endpointPath, maxBytes: 1_024) == next.endpoint + "\n",
              ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.activeConfigPath, maxBytes: 1_048_576)) == r.activeSHA256,
              ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 1_048_576)) == r.dnsSHA256 else { throw denied() }
        _ = try evidence(r, owner: old)
    }

    func authorize(_ request: ProtectedOwnerTransferRequest, uid: UInt32, validateOwner: () throws -> OwnerSession) throws -> String {
        let store = HelperStateStore(fileSystem: files, paths: paths, dateProvider: clock)
        return try store.withOperationLock(staleAfter: 120) {
            let owner = try validateOwner()
            guard ProtectedOwnerTransferRecord.validOwner(owner.payload) != nil,
                  ProtectedReplacementJournal.digest(owner.token) == request.replacement.ownerTokenSHA256 else { throw denied() }
            if files.pathPresence(at: recordPath) != .absent {
                let saved = try readRecord()
                if saved.phase != "transferred" {
                    guard saved.phase == "authorized", saved.oldOwner == owner.payload, saved.matches(request, uid: uid) else { throw denied() }
                    try liveWindow(saved); try checkArtifacts(saved)
                    guard try validateOwner() == owner else { throw denied() }
                    return "restart-authorized transaction_id=\(saved.transactionID) expires_at=\(saved.expiresAt)\n"
                }
                // A completed receipt cannot authorize another transfer. A
                // fresh consent by the currently proved owner may replace it,
                // but only after the full new journal/receipt admission below.
            }
            let now = clock.now.timeIntervalSince1970
            guard now.isFinite, now > 0, now < 9_000_000_000 else { throw denied() }
            let sessionText = try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096)
            guard let session = HelperSession(payload: sessionText), session.payload == sessionText, session.ownerPID == owner.pid,
                  session.socketExists, session.antiLeakArmed, session.dnsHealthy, session.routeInterface == session.interfaceName,
                  !session.ipv6RouteExpected || session.ipv6RouteInterface == session.interfaceName else { throw denied() }
            let kind: String, proof: String
            switch files.pathPresence(at: journalPath) {
            case .unknown: throw denied()
            case .present:
                kind = "journal"; proof = try files.readPrivateText(at: journalPath, maxBytes: 1_048_576)
                let journal = try ProtectedReplacementJournal.decode(proof)
                guard try journal.encoded() == proof, request.replacement.matches(journal), journal.ownerSession == owner.payload else { throw denied() }
            case .absent:
                kind = "receipt"; proof = try files.readPrivateText(at: receiptPath, maxBytes: 16_384)
                guard try ProtectedReplacementCommitReceipt.decode(proof).matches(request.replacement, owner: owner) else { throw denied() }
            }
            let r = ProtectedOwnerTransferRecord(schemaVersion: 1, phase: "authorized", transactionID: request.replacement.transactionID,
                sourceSHA256: request.replacement.sourceSHA256, candidateSHA256: request.replacement.candidateSHA256,
                capabilitySHA256: ProtectedReplacementJournal.digest(request.capability), uid: uid,
                issuedAt: UInt64(now), expiresAt: UInt64(now) + 120, kind: kind, oldOwner: owner.payload, newOwner: nil,
                session: sessionText, evidenceSHA256: ProtectedReplacementJournal.digest(proof),
                activeSHA256: ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.activeConfigPath, maxBytes: 1_048_576)),
                dnsSHA256: ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 1_048_576)))
            try checkArtifacts(r)
            guard try validateOwner() == owner else { throw denied() }
            try save(r); try checkArtifacts(r)
            guard try validateOwner() == owner else { throw denied() }
            return "restart-authorized transaction_id=\(r.transactionID) expires_at=\(r.expiresAt)\n"
        }
    }

    func adopt(_ request: ProtectedOwnerTransferRequest, uid: UInt32, validatePeer: () throws -> OwnerSession,
               validatePreviousIdentity: (OwnerSession) throws -> Void) throws -> String {
        let store = HelperStateStore(fileSystem: files, paths: paths, dateProvider: clock)
        return try store.withOperationLock(staleAfter: 120) {
            var r = try readRecord()
            guard r.matches(request, uid: uid) else { throw denied() }
            try liveWindow(r)
            let old = OwnerSession(payload: r.oldOwner)!, peer = try validatePeer()
            guard peer.pid != old.pid else { throw denied() }
            try validatePreviousIdentity(old); try checkArtifacts(r)
            if r.phase == "authorized" {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw denied() }
                let token = bytes.map { String(format: "%02x", $0) }.joined()
                r.newOwner = OwnerSession(pid: peer.pid, token: token, identity: peer.identity).payload
                r.phase = "adopting"
                // No dependent ownership write precedes this durable fence.
                guard try validatePeer() == peer else { throw denied() }
                try validatePreviousIdentity(old); try save(r)
            }
            guard let text = r.newOwner, let nextOwner = ProtectedOwnerTransferRecord.validOwner(text),
                  nextOwner.pid == peer.pid, nextOwner.identity == peer.identity else { throw denied() }
            func verify() throws {
                try self.liveWindow(r)
                let current = try validatePeer()
                guard current.pid == nextOwner.pid, current.identity == nextOwner.identity,
                      try self.readRecord().encoded() == r.encoded() else { throw self.denied() }
                try validatePreviousIdentity(old); try self.checkArtifacts(r)
            }
            try verify()
            var nextSession = HelperSession(payload: r.session)!; nextSession.ownerPID = nextOwner.pid
            let (proofPath, proofText, proofLimit) = try evidence(r, owner: nextOwner)
            if r.phase == "adopting" {
                try write(nextOwner.payload, path: paths.ownerSessionPath, maxBytes: 2_048); try verify()
                try write(nextSession.payload, path: paths.sessionStatePath, maxBytes: 4_096); try verify()
                try write(proofText, path: proofPath, maxBytes: proofLimit); try verify()
            }
            guard try files.readPrivateText(at: paths.ownerSessionPath, maxBytes: 2_048) == nextOwner.payload,
                  try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096) == nextSession.payload,
                  try files.readPrivateText(at: proofPath, maxBytes: proofLimit) == proofText else { throw denied() }
            if r.phase == "adopting" {
                r.phase = "transferred"; try save(r); try verify()
            }
            // Retain a bounded completion receipt for lost-ACK retry by this
            // exact new PID/start identity only. It grants no further transfer.
            return "owner-transferred restart_protocol=1 transaction_id=\(r.transactionID) source_sha256=\(r.sourceSHA256) candidate_sha256=\(r.candidateSHA256) owner_token_sha256=\(ProtectedReplacementJournal.digest(nextOwner.token)) evidence_kind=\(r.kind)\n"
        }
    }

    func cancel(_ request: ProtectedOwnerTransferRequest, uid: UInt32, validateOwner: () throws -> OwnerSession) throws -> String {
        let store = HelperStateStore(fileSystem: files, paths: paths, dateProvider: clock)
        return try store.withOperationLock(staleAfter: 120) {
            let owner = try validateOwner(), r = try readRecord()
            guard r.phase == "authorized", r.oldOwner == owner.payload, r.matches(request, uid: uid) else { throw denied() }
            try checkArtifacts(r)
            guard try validateOwner() == owner else { throw denied() }
            try files.removeItem(at: recordPath)
            guard files.pathPresence(at: recordPath) == .absent else { throw denied() }
            return "restart-cancelled transaction_id=\(r.transactionID)\n"
        }
    }
}

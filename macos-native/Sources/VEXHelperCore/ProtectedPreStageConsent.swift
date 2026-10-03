import Foundation

/// Separate from owner-transfer.state: this original-live-owner consent can
/// enter replacement, but cannot transfer ownership or prove a commit by itself.
/// No raw capability or profile/key material is stored or returned.
public protocol ProtectedPreStageConsentControlling: Sendable {
    func authorizeProtectedStage(request: ProtectedOwnerTransferRequest, uid: UInt32,
        validateOwner: () throws -> OwnerSession) throws -> String
    func cancelProtectedStage(request: ProtectedOwnerTransferRequest, uid: UInt32,
        validateOwner: () throws -> OwnerSession) throws -> String
    func replaceWithPreStageConsent(request: ProtectedReplacementRequest, uid: UInt32, consentCapabilitySHA256: String,
        validateOwner: () throws -> OwnerSession) throws -> HelperSession
}

struct ProtectedPreStageConsent: Codable {
    let schemaVersion: Int
    let transactionID: String
    let sourceSHA256: String
    let candidateSHA256: String
    let capabilitySHA256: String
    let uid: UInt32
    let issuedAt: UInt64
    let expiresAt: UInt64
    let ownerSession: String
    let sourceSession: String
    let dnsSHA256: String
    let policySHA256: String

    static func policy(candidate: String, session: String, dns: String) -> String {
        ProtectedReplacementJournal.digest("vex-pre-stage-policy-v1\n" + candidate + "\n"
            + ProtectedReplacementJournal.digest(session) + "\n" + dns + "\n")
    }
    func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }
    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16_384,
              let r = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              r.schemaVersion == 1, UUID(uuidString: r.transactionID)?.uuidString == r.transactionID,
              [r.sourceSHA256, r.candidateSHA256, r.capabilitySHA256, r.dnsSHA256, r.policySHA256]
                .allSatisfy(ProtectedOwnerTransferRequest.isDigest), r.sourceSHA256 != r.candidateSHA256,
              r.issuedAt > 0, r.issuedAt < 9_000_000_000, r.expiresAt == r.issuedAt + 120,
              let owner = ProtectedOwnerTransferRecord.validOwner(r.ownerSession),
              let session = HelperSession(payload: r.sourceSession), session.payload == r.sourceSession,
              r.sourceSession.utf8.count <= 4_096, !r.sourceSession.utf8.contains(0), session.ownerPID == owner.pid,
              session.socketExists, session.antiLeakArmed, session.dnsHealthy,
              session.routeInterface == session.interfaceName,
              !session.ipv6RouteExpected || session.ipv6RouteInterface == session.interfaceName,
              r.policySHA256 == policy(candidate: r.candidateSHA256, session: r.sourceSession, dns: r.dnsSHA256),
              (try? r.encoded()) == text else { throw denied() }
        return r
    }
    static func denied() -> HelperError { .ownerVerificationFailed("protected stage authorization denied") }
    func matches(_ request: ProtectedReplacementRequest, owner: OwnerSession) -> Bool {
        transactionID == request.transactionID && sourceSHA256 == request.sourceSHA256
            && candidateSHA256 == request.candidateSHA256 && ownerSession == owner.payload
            && ProtectedReplacementJournal.digest(owner.token) == request.ownerTokenSHA256
    }
    func matches(_ request: ProtectedOwnerTransferRequest, uid: UInt32) -> Bool {
        guard let owner = OwnerSession(payload: ownerSession) else { return false }
        return self.uid == uid && matches(request.replacement, owner: owner)
            && capabilitySHA256 == ProtectedReplacementJournal.digest(request.capability)
    }
}

/// Called under the existing kernel lease. Attachment is the journal's optional
/// digest of this immutable consent; no phase/expiry/dead PID alone consumes it.
final class ProtectedPreStageConsentStore {
    private let files: HelperFileSystem
    private let paths: HelperPathsLayout
    private let clock: DateProviding
    var recordPath: String { paths.helperDirectory + "/protected-pre-stage-consent.state" }
    private var journalPath: String { paths.helperDirectory + "/replacement-journal.state" }
    private var receiptPath: String { paths.helperDirectory + "/replacement-commit-receipt.state" }
    init(files: HelperFileSystem, paths: HelperPathsLayout, clock: DateProviding) {
        self.files = files; self.paths = paths; self.clock = clock
    }
    func read() throws -> ProtectedPreStageConsent {
        guard files.pathPresence(at: recordPath) == .present else { throw ProtectedPreStageConsent.denied() }
        return try ProtectedPreStageConsent.decode(files.readPrivateText(at: recordPath, maxBytes: 16_384))
    }
    private func live(_ r: ProtectedPreStageConsent) throws {
        let now = clock.now.timeIntervalSince1970
        guard now.isFinite, now >= Double(r.issuedAt), now < Double(r.expiresAt) else { throw ProtectedPreStageConsent.denied() }
    }
    private func sourceArtifacts(_ r: ProtectedPreStageConsent) throws {
        let session = HelperSession(payload: r.sourceSession)!
        guard try files.readPrivateText(at: paths.ownerSessionPath, maxBytes: 2_048) == r.ownerSession,
              try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096) == r.sourceSession,
              try files.readPrivateText(at: paths.interfacePath, maxBytes: 128) == session.interfaceName + "\n",
              try files.readPrivateText(at: paths.endpointPath, maxBytes: 1_024) == session.endpoint + "\n",
              ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.activeConfigPath, maxBytes: 262_144)) == r.sourceSHA256,
              ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 262_144)) == r.dnsSHA256
        else { throw ProtectedPreStageConsent.denied() }
    }
    func authorize(_ request: ProtectedOwnerTransferRequest, uid: UInt32, candidate: () throws -> String,
        validateOwner: () throws -> OwnerSession, validateSource: () throws -> Void) throws -> String {
        let store = HelperStateStore(fileSystem: files, paths: paths, dateProvider: clock)
        return try store.withOperationLock(staleAfter: 120) {
            try store.requireNoPendingReplacement()
            let owner = try validateOwner(); try validateSource()
            let staged = try candidate(); try AwgConfigAdmission.validate(staged)
            guard ProtectedOwnerTransferRecord.validOwner(owner.payload) != nil,
                  ProtectedReplacementJournal.digest(owner.token) == request.replacement.ownerTokenSHA256,
                  ProtectedReplacementJournal.digest(staged) == request.replacement.candidateSHA256 else { throw ProtectedPreStageConsent.denied() }
            let now = clock.now.timeIntervalSince1970
            guard now.isFinite, now > 0, now < 9_000_000_000 else { throw ProtectedPreStageConsent.denied() }
            let session = try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096)
            let dns = ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 262_144))
            var r = ProtectedPreStageConsent(schemaVersion: 1, transactionID: request.replacement.transactionID,
                sourceSHA256: request.replacement.sourceSHA256, candidateSHA256: request.replacement.candidateSHA256,
                capabilitySHA256: ProtectedReplacementJournal.digest(request.capability), uid: uid,
                issuedAt: UInt64(now), expiresAt: UInt64(now) + 120, ownerSession: owner.payload, sourceSession: session,
                dnsSHA256: dns, policySHA256: ProtectedPreStageConsent.policy(candidate: request.replacement.candidateSHA256, session: session, dns: dns))
            if files.pathPresence(at: recordPath) != .absent {
                let prior = try read()
                if prior.matches(request, uid: uid) {
                    guard prior.ownerSession == owner.payload else { throw ProtectedPreStageConsent.denied() }
                    r = prior
                } else {
                    // Only a proved completed attachment can be replaced by a
                    // different fresh consent from the current live owner.
                    guard try completedAttachment(prior) else { throw ProtectedPreStageConsent.denied() }
                }
            }
            try live(r); try sourceArtifacts(r); try validateSource()
            guard try validateOwner() == owner, try candidate() == staged else { throw ProtectedPreStageConsent.denied() }
            let text = try r.encoded(); _ = try ProtectedPreStageConsent.decode(text)
            try files.writeTextAtomically(text, to: recordPath, mode: 0o600)
            guard try read().encoded() == text, try validateOwner() == owner, try candidate() == staged else { throw ProtectedPreStageConsent.denied() }
            try sourceArtifacts(r); try validateSource(); try live(r)
            return "stage-authorized transaction_id=\(r.transactionID) expires_at=\(r.expiresAt)\n"
        }
    }
    /// This is the ONLY attachment path, after exact candidate admission and
    /// before journal persistence / any fake or real PF, quick, active/DNS write.
    func attach(request: ProtectedReplacementRequest, uid: UInt32?, owner: OwnerSession,
        journal: ProtectedReplacementJournal, required: Bool, capabilitySHA256: String?) throws -> String? {
        if files.pathPresence(at: recordPath) == .absent {
            guard !required else { throw ProtectedPreStageConsent.denied() }
            return nil // legacy client with no stage consent, not a fallback
        }
        let r = try read()
        if !required, !r.matches(request, owner: owner), try completedAttachment(r) { return nil }

        guard r.uid == uid, (!required || r.capabilitySHA256 == capabilitySHA256), r.matches(request, owner: owner), journal.sourceSession == r.sourceSession,
              journal.ownerSession == r.ownerSession, request.matches(journal), journal.phase == "prepared",
              journal.handshakeNotBefore != nil, ProtectedReplacementJournal.digest(journal.dnsBaseline) == r.dnsSHA256,
              ProtectedPreStageConsent.policy(candidate: journal.candidateSHA256, session: journal.sourceSession,
                dns: ProtectedReplacementJournal.digest(journal.dnsBaseline)) == r.policySHA256 else { throw ProtectedPreStageConsent.denied() }
        try live(r); try sourceArtifacts(r)
        return ProtectedReplacementJournal.digest(try r.encoded())
    }
    func verifyPreparedAttachment(_ journal: ProtectedReplacementJournal) throws {
        guard let binding = journal.preStageConsentSHA256 else { return }
        let r = try read()
        guard binding == ProtectedReplacementJournal.digest(try r.encoded()),
              journal.transactionID == r.transactionID, journal.sourceSHA256 == r.sourceSHA256,
              journal.candidateSHA256 == r.candidateSHA256, journal.ownerSession == r.ownerSession,
              journal.sourceSession == r.sourceSession, ProtectedReplacementJournal.digest(journal.dnsBaseline) == r.dnsSHA256
        else { throw ProtectedPreStageConsent.denied() }
        try live(r); try sourceArtifacts(r)
    }

    func completedAttachment(_ r: ProtectedPreStageConsent) throws -> Bool {
        guard files.pathPresence(at: journalPath) == .absent, files.pathPresence(at: receiptPath) == .present else { return false }
        let receipt = try ProtectedReplacementCommitReceipt.decode(files.readPrivateText(at: receiptPath, maxBytes: 16_384))
        let owner = OwnerSession(payload: r.ownerSession)!
        return receipt.preStageConsentSHA256 == ProtectedReplacementJournal.digest(try r.encoded())
            && receipt.transactionID == r.transactionID && receipt.sourceSHA256 == r.sourceSHA256
            && receipt.candidateSHA256 == r.candidateSHA256 && receipt.ownerPID == owner.pid
            && receipt.ownerIdentity == owner.identity && receipt.ownerTokenSHA256 == ProtectedReplacementJournal.digest(owner.token)
    }
    /// Convert a previously live, exactly attached consent into the existing
    /// transfer fence. No attachment => no ownership write, even after owner death.
    func restartAuthorization(_ request: ProtectedOwnerTransferRequest, uid: UInt32) throws -> ProtectedOwnerTransferRecord {
        let r = try read(); guard r.matches(request, uid: uid) else { throw ProtectedPreStageConsent.denied() }; try live(r)
        let proof: String, kind: String
        if files.pathPresence(at: journalPath) == .present {
            proof = try files.readPrivateText(at: journalPath, maxBytes: 1_048_576)
            let j = try ProtectedReplacementJournal.decode(proof)
            guard try j.encoded() == proof, j.preStageConsentSHA256 == ProtectedReplacementJournal.digest(try r.encoded()),
                  request.replacement.matches(j), j.ownerSession == r.ownerSession, j.sourceSession == r.sourceSession,
                  ProtectedReplacementJournal.digest(j.dnsBaseline) == r.dnsSHA256 else { throw ProtectedPreStageConsent.denied() }
            kind = "journal"
        } else {
            guard try completedAttachment(r) else { throw ProtectedPreStageConsent.denied() }
            proof = try files.readPrivateText(at: receiptPath, maxBytes: 16_384); kind = "receipt"
        }
        let active = ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.activeConfigPath, maxBytes: 262_144))
        guard [r.sourceSHA256, r.candidateSHA256].contains(active), kind != "receipt" || active == r.candidateSHA256,
              try files.readPrivateText(at: paths.ownerSessionPath, maxBytes: 2_048) == r.ownerSession,
              ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 262_144)) == r.dnsSHA256
        else { throw ProtectedPreStageConsent.denied() }
        return ProtectedOwnerTransferRecord(schemaVersion: 1, phase: "authorized", transactionID: r.transactionID,
            sourceSHA256: r.sourceSHA256, candidateSHA256: r.candidateSHA256, capabilitySHA256: r.capabilitySHA256,
            uid: r.uid, issuedAt: r.issuedAt, expiresAt: r.expiresAt, kind: kind, oldOwner: r.ownerSession, newOwner: nil,
            session: try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096),
            evidenceSHA256: ProtectedReplacementJournal.digest(proof), activeSHA256: active, dnsSHA256: r.dnsSHA256)
    }
    func cancel(_ request: ProtectedOwnerTransferRequest, uid: UInt32, validateOwner: () throws -> OwnerSession) throws -> String {
        let store = HelperStateStore(fileSystem: files, paths: paths, dateProvider: clock)
        return try store.withOperationLock(staleAfter: 120) {
            try store.requireNoPendingReplacement()
            let owner = try validateOwner(), r = try read()
            guard r.ownerSession == owner.payload, r.matches(request, uid: uid) else { throw ProtectedPreStageConsent.denied() }
            // Expiry is never takeover authority, but the same live original
            // owner may cancel an unconsumed record. Only this private file goes.
            if try !completedAttachment(r) {
                // Source recovery may have a new utun/handshake, but not a new
                // owner/config/DNS. Cancellation only retires private metadata;
                // it cannot use a candidate or stale UI status as source proof.
                guard ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.activeConfigPath, maxBytes: 262_144)) == r.sourceSHA256,
                      ProtectedReplacementJournal.digest(try files.readPrivateText(at: paths.dnsStatePath, maxBytes: 262_144)) == r.dnsSHA256,
                      try files.readPrivateText(at: paths.ownerSessionPath, maxBytes: 2_048) == r.ownerSession,
                      let saved = HelperSession(payload: try files.readPrivateText(at: paths.sessionStatePath, maxBytes: 4_096)),
                      saved.ownerPID == owner.pid, saved.endpoint == HelperSession(payload: r.sourceSession)!.endpoint,
                      saved.socketExists, saved.antiLeakArmed, saved.dnsHealthy,
                      saved.routeInterface == saved.interfaceName,
                      !saved.ipv6RouteExpected || saved.ipv6RouteInterface == saved.interfaceName,
                      try files.readPrivateText(at: paths.interfacePath, maxBytes: 128) == saved.interfaceName + "\n",
                      try files.readPrivateText(at: paths.endpointPath, maxBytes: 1_024) == saved.endpoint + "\n"
                else { throw ProtectedPreStageConsent.denied() }
            }
            guard try validateOwner() == owner else { throw ProtectedPreStageConsent.denied() }
            try files.removeItem(at: recordPath)
            guard files.pathPresence(at: recordPath) == .absent else { throw ProtectedPreStageConsent.denied() }
            return "stage-cancelled transaction_id=\(r.transactionID)\n"
        }
    }
}

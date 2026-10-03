import CryptoKit
import Foundation

/// Root-private recovery data. Configurations contain keys: never log this
/// object, its JSON, or underlying command stdout/stderr.
struct ProtectedReplacementJournal: Codable {
    static let schema = 1
    var schemaVersion = Self.schema
    var transactionID = UUID().uuidString
    var phase = "prepared"
    let ownerPID: Int32
    let sourceSession: String
    let sourceConfig: String
    let sourceSHA256: String
    let candidateConfig: String
    let candidateSHA256: String
    let dnsBaseline: String
    // Full owner token + process-start identity, not PID alone. Optional for
    // pre-integration journals that were created with no registered owner.
    let ownerSession: String?
    // Absent in legacy foundation journals. New socket transactions cannot
    // delete recovery evidence until an uncached post-cutover handshake exists.
    var handshakeNotBefore: UInt64? = nil
    // Optional additive binding; legacy journals keep their exact encoding.
    var preStageConsentSHA256: String? = nil

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 1_048_576,
              let journal = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              journal.schemaVersion == schema,
              UUID(uuidString: journal.transactionID) != nil,
              ["prepared", "replacing", "awaiting-handshake", "rolling-back", "committed"].contains(journal.phase),
              journal.ownerPID > 1,
              let source = HelperSession(payload: journal.sourceSession),
              source.ownerPID == journal.ownerPID, source.antiLeakArmed,
              digest(journal.sourceConfig) == journal.sourceSHA256,
              digest(journal.candidateConfig) == journal.candidateSHA256,
              journal.sourceSHA256 != journal.candidateSHA256,
              !journal.dnsBaseline.isEmpty else {
            throw HelperError.protocolViolation("invalid protected replacement recovery journal")
        }
        try AwgConfigAdmission.validate(journal.sourceConfig)
        try AwgConfigAdmission.validate(journal.candidateConfig)
        if let text = journal.ownerSession {
            guard text.utf8.count <= 16_384, let owner = OwnerSession(payload: text),
                  owner.pid == journal.ownerPID, !owner.token.isEmpty,
                  !owner.identity.isEmpty, text == owner.payload else {
                throw HelperError.protocolViolation("invalid protected replacement journal owner")
            }
        }
        if journal.phase == "awaiting-handshake" || journal.handshakeNotBefore != nil {
            guard journal.ownerSession != nil, let floor = journal.handshakeNotBefore, floor > 0 else {
                throw HelperError.protocolViolation("invalid protected replacement handshake journal")
            }
        }
        if let consent = journal.preStageConsentSHA256 {
            guard ProtectedOwnerTransferRequest.isDigest(consent), journal.ownerSession != nil,
                  journal.handshakeNotBefore != nil else { throw HelperError.protocolViolation("invalid protected stage journal binding") }
        }
        return journal
    }
}

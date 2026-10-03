import Foundation

/// Root-private, bounded commit proof. Contains hashes and process identity,
/// never profile bytes, private keys, the raw owner token or customer identity.
/// It is evidence, not permission to attach/adopt/transfer ownership.
struct ProtectedReplacementCommitReceipt: Codable {
    let schemaVersion: Int
    let transactionID: String
    let sourceSHA256: String
    let candidateSHA256: String
    let ownerTokenSHA256: String
    let ownerPID: Int32
    let ownerIdentity: String
    let latestHandshake: UInt64
    let handshakeNotBefore: UInt64
    let sourceLatestHandshake: UInt64
    var preStageConsentSHA256: String? = nil

    init(request: ProtectedReplacementRequest, owner: OwnerSession, latestHandshake: UInt64,
         handshakeNotBefore: UInt64, sourceLatestHandshake: UInt64) {
        schemaVersion = 1
        transactionID = request.transactionID
        sourceSHA256 = request.sourceSHA256
        candidateSHA256 = request.candidateSHA256
        ownerTokenSHA256 = request.ownerTokenSHA256
        ownerPID = owner.pid
        ownerIdentity = owner.identity
        self.latestHandshake = latestHandshake
        self.handshakeNotBefore = handshakeNotBefore
        self.sourceLatestHandshake = sourceLatestHandshake
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16_384,
              let receipt = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              receipt.schemaVersion == 1,
              UUID(uuidString: receipt.transactionID)?.uuidString == receipt.transactionID,
              isDigest(receipt.sourceSHA256), isDigest(receipt.candidateSHA256), isDigest(receipt.ownerTokenSHA256),
              receipt.sourceSHA256 != receipt.candidateSHA256,
              receipt.ownerPID > 1, !receipt.ownerIdentity.isEmpty, receipt.ownerIdentity.utf8.count <= 1_024,
              !receipt.ownerIdentity.utf8.contains(0),
              receipt.handshakeNotBefore > 0, receipt.latestHandshake >= receipt.handshakeNotBefore,
              receipt.latestHandshake > receipt.sourceLatestHandshake,
              // Reject unknown/duplicate fields, noncanonical numbers and partial
              // writes; production writes exactly this canonical representation.
              (try? receipt.encoded()) == text else {
            throw HelperError.protocolViolation("invalid protected commit receipt")
        }
        if let consent = receipt.preStageConsentSHA256 {
            guard ProtectedOwnerTransferRequest.isDigest(consent) else { throw HelperError.protocolViolation("invalid protected stage receipt binding") }
        }
        return receipt
    }

    func matches(_ request: ProtectedReplacementRequest, owner: OwnerSession) -> Bool {
        transactionID == request.transactionID && sourceSHA256 == request.sourceSHA256
            && candidateSHA256 == request.candidateSHA256 && ownerTokenSHA256 == request.ownerTokenSHA256
            && ownerPID == owner.pid && ownerIdentity == owner.identity
            && ownerTokenSHA256 == ProtectedReplacementJournal.digest(owner.token)
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var response: String {
        "committed commit_receipt_protocol=1 transaction_id=\(transactionID) source_sha256=\(sourceSHA256) candidate_sha256=\(candidateSHA256) owner_token_sha256=\(ownerTokenSHA256) latest_handshake=\(latestHandshake)\n"
    }
}

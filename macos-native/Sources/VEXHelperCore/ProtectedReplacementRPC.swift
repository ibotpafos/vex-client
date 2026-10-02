import Foundation

/// Only non-secret compare-and-swap identities cross the command socket. The
/// candidate stays in the existing admitted config file, never in RPC/log text.
public struct ProtectedReplacementRequest: Equatable, Sendable {
    public let transactionID: String
    public let sourceSHA256: String
    public let candidateSHA256: String
    public let ownerTokenSHA256: String

    public init(metadata: [String]) throws {
        var fields: [String: String] = [:]
        let expected: Set<String> = ["transaction_id", "source_sha256", "candidate_sha256", "owner_token_sha256"]
        for item in metadata {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, expected.contains(String(parts[0])),
                  fields.updateValue(String(parts[1]), forKey: String(parts[0])) == nil else {
                throw HelperError.protocolViolation("invalid protected replacement metadata")
            }
        }
        guard Set(fields.keys) == expected,
              let transaction = fields["transaction_id"],
              let uuid = UUID(uuidString: transaction), uuid.uuidString == transaction,
              let source = fields["source_sha256"], Self.isDigest(source),
              let candidate = fields["candidate_sha256"], Self.isDigest(candidate), source != candidate,
              let owner = fields["owner_token_sha256"], Self.isDigest(owner) else {
            throw HelperError.protocolViolation("invalid protected replacement metadata")
        }
        transactionID = transaction
        sourceSHA256 = source
        candidateSHA256 = candidate
        ownerTokenSHA256 = owner
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func matches(_ journal: ProtectedReplacementJournal) -> Bool {
        transactionID == journal.transactionID && sourceSHA256 == journal.sourceSHA256
            && candidateSHA256 == journal.candidateSHA256
            && journal.ownerSession.flatMap(OwnerSession.init(payload:)).map {
                ProtectedReplacementJournal.digest($0.token) == ownerTokenSHA256
            } == true
    }
}

/// The controller owns the kernel operation lease. Runtime authorization is
/// rechecked inside that lease and at each mutation boundary, never by nesting
/// an ordinary-operation lease (which intentionally rejects pending journals).
public protocol ProtectedTunnelControlling: TunnelControlling {
    func protectedReplacementSnapshot(validateOwner: () throws -> OwnerSession) throws -> String
    func replaceProtected(request: ProtectedReplacementRequest, validateOwner: () throws -> OwnerSession) throws -> HelperSession
    func commitProtected(request: ProtectedReplacementRequest, validateOwner: () throws -> OwnerSession) throws -> HelperSession
    func recoverProtected(request: ProtectedReplacementRequest, validateOwner: () throws -> OwnerSession) throws -> HelperSession?
}

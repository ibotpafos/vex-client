import Foundation

/// Memory-only bytes from a confirmed normal admission or protected commit.
/// Never reconstruct a source by resolving its hostname again, or populate this
/// store from disk, a status hint, an unverified snapshot, or a prepared profile.
@MainActor
final class NativeAdmittedProfileStore {
    struct Scope: Equatable {
        let accountID: String
        let installationID: String
        let sessionGeneration: Int
    }

    struct Source {
        let revision: UUID
        let tunnel: PreparedTunnel
        let canonicalConfig: String
        let ownerTokenSHA256: String
        fileprivate let scope: Scope
    }

    enum Failure: Error { case invalidAdmission, staleSource }
    private var admitted: Source?
    private weak var ownerHelper: AnyObject?

    /// Caller must already have matched these exact bytes against the
    /// authenticated helper admission/commit receipt. No helper query here can
    /// turn an arbitrary prepared profile into an admitted source.
    @discardableResult
    func record(tunnel: PreparedTunnel, canonicalConfig: String, ownerTokenSHA256: String,
                scope: Scope, helper: AnyObject) throws -> Source {
        guard !scope.accountID.isEmpty, !scope.installationID.isEmpty, scope.sessionGeneration >= 0,
              !canonicalConfig.isEmpty, canonicalConfig.utf8.count <= 262_144,
              ownerTokenSHA256.utf8.count == 64,
              ownerTokenSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidAdmission
        }
        let source = Source(revision: UUID(), tunnel: tunnel, canonicalConfig: canonicalConfig,
                            ownerTokenSHA256: ownerTokenSHA256, scope: scope)
        admitted = source
        ownerHelper = helper
        return source
    }

    func source(for tunnel: PreparedTunnel, scope: Scope, helper: AnyObject) throws -> Source {
        guard let admitted, ownerHelper === helper,
              admitted.scope == scope, admitted.tunnel == tunnel else { throw Failure.staleSource }
        return admitted
    }

    func isCurrent(_ source: Source, scope: Scope, helper: AnyObject) -> Bool {
        (try? self.source(for: source.tunnel, scope: scope, helper: helper).revision) == source.revision
    }

    func clear() {
        admitted = nil
        ownerHelper = nil
    }
}

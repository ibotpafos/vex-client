import Foundation

/// Memory-only bytes from a confirmed normal admission or protected commit.
/// Never reconstruct a source by resolving its hostname again, or populate this
/// admission from disk, a status hint, an unverified snapshot, or a prepared profile.
/// Pending candidate material is a separate, memory-only intent, NOT admission.
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

    struct Candidate {
        let revision: UUID
        let tunnel: PreparedTunnel
        let canonicalConfig: String
        fileprivate let sourceRevision: UUID
        fileprivate let sourceOwnerTokenSHA256: String
        fileprivate let scope: Scope
        fileprivate let intentFingerprint: String
        fileprivate let generation: Int
    }

    enum Failure: Error { case invalidAdmission, staleSource, invalidCandidate, staleCandidate, missingCandidate }
    private var admitted: Source?
    private weak var ownerHelper: AnyObject?
    private var pendingCandidate: Candidate?
    private weak var candidateHelper: AnyObject?

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
        if let pendingCandidate, !(pendingCandidate.tunnel == tunnel
            && pendingCandidate.canonicalConfig == canonicalConfig
            && pendingCandidate.sourceOwnerTokenSHA256 == ownerTokenSHA256
            && pendingCandidate.scope == scope && candidateHelper === helper) {
            forgetCandidate(pendingCandidate)
        }
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

    /// Private terminal completion only; neither records nor admits a profile.
    func forgetRetiredCandidate(intentFingerprint: String, generation: Int, helper: AnyObject) {
        guard let candidate = pendingCandidate, candidateHelper === helper,
              candidate.intentFingerprint == intentFingerprint, candidate.generation == generation else { return }
        forgetCandidate(candidate)
    }

    /// Keep the exact resolved bytes before any helper mutation. A later signed
    /// profile/owner/intent mismatch cannot overwrite or silently re-resolve them.
    func recordCandidate(tunnel: PreparedTunnel, canonicalConfig: String, source: Source,
                         scope: Scope, helper: AnyObject, intentFingerprint: String, generation: Int) throws -> Candidate {
        guard isCurrent(source, scope: scope, helper: helper), !canonicalConfig.isEmpty,
              canonicalConfig.utf8.count <= 262_144, generation >= 0,
              intentFingerprint.utf8.count == 64,
              intentFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidCandidate
        }
        if let existing = try candidate(for: tunnel, scope: scope, helper: helper,
            intentFingerprint: intentFingerprint, generation: generation, source: source) {
            guard existing.canonicalConfig == canonicalConfig else { throw Failure.staleCandidate }
            return existing
        }
        let value = Candidate(revision: UUID(), tunnel: tunnel, canonicalConfig: canonicalConfig,
            sourceRevision: source.revision, sourceOwnerTokenSHA256: source.ownerTokenSHA256,
            scope: scope, intentFingerprint: intentFingerprint, generation: generation)
        pendingCandidate = value
        candidateHelper = helper
        return value
    }

    func candidate(for tunnel: PreparedTunnel, scope: Scope, helper: AnyObject,
                   intentFingerprint: String, generation: Int, source: Source? = nil) throws -> Candidate? {
        guard let pendingCandidate else { return nil }
        guard candidateHelper === helper, pendingCandidate.scope == scope,
              pendingCandidate.tunnel == tunnel, pendingCandidate.intentFingerprint == intentFingerprint,
              pendingCandidate.generation == generation else { throw Failure.staleCandidate }
        if let source {
            guard pendingCandidate.sourceRevision == source.revision,
                  pendingCandidate.sourceOwnerTokenSHA256 == source.ownerTokenSHA256,
                  isCurrent(source, scope: scope, helper: helper) else { throw Failure.staleCandidate }
        }
        return pendingCandidate
    }

    func isCurrent(_ material: Candidate, scope: Scope, helper: AnyObject) -> Bool {
        (try? candidate(for: material.tunnel, scope: scope, helper: helper,
            intentFingerprint: material.intentFingerprint, generation: material.generation)?.revision) == material.revision
    }

    /// Exact revision only; an old completion cannot erase a newer intent.
    func forgetCandidate(_ material: Candidate) {
        guard pendingCandidate?.revision == material.revision else { return }
        pendingCandidate = nil
        candidateHelper = nil
    }

    func clear() {
        admitted = nil
        ownerHelper = nil
        pendingCandidate = nil
        candidateHelper = nil
    }
}

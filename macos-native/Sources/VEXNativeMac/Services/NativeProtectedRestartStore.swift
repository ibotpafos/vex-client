import Foundation
import Security

/// Sensitive material and one-use capability have separate, bounded private
/// custody. Neither record is admission. The signed policy/current key and fresh
/// authenticated root receipt must be checked before cache/admission promotion.
struct NativeProtectedRestartStore {
    struct Material: Codable, Equatable {
        let schema: Int
        let namespace: String
        let ownerFingerprint: String
        let intent: NativeProtectedReplacementCoordinator.RestartIntent
        let rotationID: String
        let source: PreparedTunnelCacheRecord
        let candidate: PreparedTunnelCacheRecord
        let sourceConfig: String
        let candidateConfig: String
        let selectedLocationID: String
        let targetLocationID: String
    }
    struct Capability: Codable, Equatable {
        let schema: Int
        let namespace: String
        let ownerFingerprint: String
        let intent: NativeProtectedReplacementCoordinator.RestartIntent
        let materialSHA256: String
        let issuedAt: UInt64
        let expiresAt: UInt64
        let value: String
    }
    // Separate purpose/ACK custody; the capability bytes are deliberately shared
    // with restart custody ONLY for the exact root journal/receipt bridge. This
    // marker never grants admission or permits post-journal TTL renewal.
    struct StageConsent: Codable, Equatable {
        let schema: Int
        let namespace: String
        let ownerFingerprint: String
        let intent: NativeProtectedReplacementCoordinator.RestartIntent
        let materialSHA256: String
        let cancelled: Bool
    }
    enum Failure: LocalizedError {
        case unavailable, mismatch, expired
        var errorDescription: String? { "Защищённое восстановление не подтверждено. Данные сохранены для явного повтора." }
    }
    private let root: URL
    init(fileManager: FileManager = .default, appDataURL: URL? = nil) {
        root = appDataURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("VEX Native", isDirectory: true)
    }
    private func fingerprint(_ owner: NativePushPSKEventOwner) throws -> String {
        guard !owner.accountID.isEmpty, !owner.installationID.isEmpty,
              owner.accountID.utf8.count <= 512, owner.installationID.utf8.count <= 512,
              !owner.accountID.utf8.contains(0), !owner.installationID.utf8.contains(0) else { throw Failure.unavailable }
        return NativeProtectedPromotionStore.fingerprint(["vex-protected-restart-v1", owner.accountID, owner.installationID])
    }
    private func encode<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(10)
        guard data.count <= limit else { throw Failure.unavailable }; return data
    }
    private func record(_ tunnel: PreparedTunnel) -> PreparedTunnelCacheRecord {
        var value = PreparedTunnelCacheRecord(tunnel: tunnel)
        value.cacheOwner = nil; value.normalAuthorizationProfile = nil; value.fetchedAt = nil
        return value
    }
    @MainActor
    func retain(owner: NativePushPSKEventOwner, intent: NativeProtectedReplacementCoordinator.RestartIntent,
        rotationID: String, source: PreparedTunnel, candidate: PreparedTunnel,
        sourceConfig: String, candidateConfig: String, selectedLocationID: String, targetLocationID: String) throws {
        let value = Material(schema: 1, namespace: "vex-protected-restart-material-v1",
            ownerFingerprint: try fingerprint(owner), intent: intent, rotationID: rotationID,
            source: record(source), candidate: record(candidate), sourceConfig: sourceConfig,
            candidateConfig: candidateConfig, selectedLocationID: selectedLocationID, targetLocationID: targetLocationID)
        let data = try encode(value, limit: 1_048_576)
        _ = try decodeMaterial(data, owner: owner)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        try store.ensureDirectory(); let name = "restart-material-" + value.ownerFingerprint + ".json"
        if let old = try store.read(name) { guard old == data else { throw Failure.mismatch }; return }
        try store.write(data, name: name)
        guard try store.read(name) == data else { throw Failure.unavailable }
    }
    func loadMaterial(owner: NativePushPSKEventOwner) throws -> Material? {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        guard let data = try store.read("restart-material-" + fingerprint(owner) + ".json") else { return nil }
        return try decodeMaterial(data, owner: owner)
    }
    private func decodeMaterial(_ data: Data, owner: NativePushPSKEventOwner) throws -> Material {
        guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(Material.self, from: data),
              value.schema == 1, value.namespace == "vex-protected-restart-material-v1",
              value.ownerFingerprint == (try fingerprint(owner)), value.intent.isValid,
              NativePSKIdentifier.rotation(value.rotationID), NativePSKIdentifier.device(value.source.device.id),
              value.source.device.id == value.candidate.device.id,
              value.source.device.externalDeviceId == owner.installationID,
              value.candidate.device.externalDeviceId == owner.installationID,
              value.source.locationId == value.candidate.locationId,
              value.source.routingMode == value.candidate.routingMode, value.source.bypassRegion == value.candidate.bypassRegion,
              value.source.awgVersion == 3, value.candidate.awgVersion == 3,
              (value.candidate.profileVersion ?? 0) > (value.source.profileVersion ?? 0),
              value.source.cacheOwner == nil, value.candidate.cacheOwner == nil,
              value.source.normalAuthorizationProfile == nil, value.candidate.normalAuthorizationProfile == nil,
              value.source.fetchedAt == nil, value.candidate.fetchedAt == nil,
              !value.selectedLocationID.isEmpty, value.selectedLocationID.utf8.count <= 512,
              value.targetLocationID == value.source.locationId,
              value.sourceConfig.utf8.count <= 524_288, value.candidateConfig.utf8.count <= 524_288,
              NativeProtectedReplacementCoordinator.digest(value.sourceConfig) == value.intent.sourceSHA256,
              NativeProtectedReplacementCoordinator.digest(value.candidateConfig) == value.intent.candidateSHA256,
              (try? encode(value, limit: 1_048_576)) == data else { throw Failure.mismatch }
        return value
    }
    func materialDigest(_ value: Material) throws -> String {
        NativeProtectedReplacementCoordinator.digest(String(decoding: try encode(value, limit: 1_048_576), as: UTF8.self))
    }
    func stageConsent(owner: NativePushPSKEventOwner, material: Material) throws -> StageConsent? {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        guard let data = try store.read("stage-consent-" + fingerprint(owner) + ".json") else { return nil }
        guard let value = try? JSONDecoder().decode(StageConsent.self, from: data), value.schema == 1,
              value.namespace == "vex-protected-stage-consent-v1", value.ownerFingerprint == (try fingerprint(owner)),
              value.intent == material.intent, value.materialSHA256 == (try materialDigest(material)),
              try loadMaterial(owner: owner) == material,
              (try? encode(value, limit: 16_384)) == data else { throw Failure.mismatch }
        return value
    }
    func retainStageConsent(owner: NativePushPSKEventOwner, material: Material) throws {
        guard try loadMaterial(owner: owner) == material else { throw Failure.mismatch }
        if let existing = try stageConsent(owner: owner, material: material) {
            guard !existing.cancelled else { throw Failure.mismatch }; return
        }
        // An existing post-journal capability is not permission to change its
        // purpose. Partial pre-stage writes retain this distinct marker first.
        guard try loadCapability(owner: owner, material: material) == nil else { throw Failure.mismatch }
        let value = StageConsent(schema: 1, namespace: "vex-protected-stage-consent-v1",
            ownerFingerprint: try fingerprint(owner), intent: material.intent,
            materialSHA256: try materialDigest(material), cancelled: false)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384), data = try encode(value, limit: 16_384)
        try store.write(data, name: "stage-consent-" + value.ownerFingerprint + ".json")
        guard try stageConsent(owner: owner, material: material) == value else { throw Failure.unavailable }
    }
    func markStageCancelled(owner: NativePushPSKEventOwner, material: Material, expected: StageConsent) throws {
        guard try stageConsent(owner: owner, material: material) == expected else { throw Failure.mismatch }
        let value = StageConsent(schema: expected.schema, namespace: expected.namespace,
            ownerFingerprint: expected.ownerFingerprint, intent: expected.intent,
            materialSHA256: expected.materialSHA256, cancelled: true)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        try store.write(encode(value, limit: 16_384), name: "stage-consent-" + value.ownerFingerprint + ".json")
        guard try stageConsent(owner: owner, material: material) == value else { throw Failure.unavailable }
    }
    /// Called BEFORE authorize RPC. A lost ACK must retry the same capability;
    /// never overwrite unresolved consent or extend its conservative local TTL.
    func capability(owner: NativePushPSKEventOwner, material: Material, now: UInt64,
        generate: () throws -> String = NativeProtectedRestartStore.randomCapability) throws -> Capability {
        guard try loadMaterial(owner: owner) == material, now > 0, now < 9_000_000_000 else { throw Failure.mismatch }
        if let old = try loadCapability(owner: owner, material: material) { try live(old, now: now); return old }
        let value = try generate()
        guard NativeProtectedReplacementCoordinator.validDigest(value) else { throw Failure.unavailable }
        let record = Capability(schema: 1, namespace: "vex-protected-restart-capability-v1",
            ownerFingerprint: try fingerprint(owner), intent: material.intent, materialSHA256: try materialDigest(material),
            issuedAt: now, expiresAt: now + 120, value: value)
        let data = try encode(record, limit: 16_384), store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = "restart-capability-" + record.ownerFingerprint + ".json"
        try store.write(data, name: name)
        guard try store.read(name) == data else { throw Failure.unavailable }; return record
    }
    func loadCapability(owner: NativePushPSKEventOwner, material: Material) throws -> Capability? {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        guard let data = try store.read("restart-capability-" + fingerprint(owner) + ".json") else { return nil }
        guard let value = try? JSONDecoder().decode(Capability.self, from: data), value.schema == 1,
              value.namespace == "vex-protected-restart-capability-v1", value.ownerFingerprint == (try fingerprint(owner)),
              value.intent == material.intent, value.materialSHA256 == (try materialDigest(material)),
              NativeProtectedReplacementCoordinator.validDigest(value.value), value.issuedAt > 0,
              value.issuedAt < 9_000_000_000, value.expiresAt == value.issuedAt + 120,
              (try? encode(value, limit: 16_384)) == data else { throw Failure.mismatch }
        return value
    }
    func live(_ value: Capability, now: UInt64) throws {
        guard now >= value.issuedAt, now < value.expiresAt else { throw Failure.expired }
    }
    /// Exact cleanup only after proved promotion/cancel. Failure retains custody;
    /// unrelated owner namespaces are never enumerated or deleted.
    func removeCapability(owner: NativePushPSKEventOwner, expected: Capability) throws {
        guard let material = try loadMaterial(owner: owner), try loadCapability(owner: owner, material: material) == expected else { throw Failure.mismatch }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = "restart-capability-" + (try fingerprint(owner)) + ".json"
        try store.remove(name); guard try store.read(name) == nil else { throw Failure.unavailable }
    }
    func removeMaterial(owner: NativePushPSKEventOwner, expected: Material) throws {
        guard try loadMaterial(owner: owner) == expected,
              try loadCapability(owner: owner, material: expected) == nil else { throw Failure.mismatch }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        // Validate the purpose record before either deletion; it carries no raw
        // capability and is removed only with the exact proved/cancelled material.
        _ = try stageConsent(owner: owner, material: expected)
        try store.remove("stage-consent-" + (try fingerprint(owner)) + ".json")
        let name = "restart-material-" + (try fingerprint(owner)) + ".json"
        try store.remove(name); guard try store.read(name) == nil else { throw Failure.unavailable }
    }
    func purge(owner: NativePushPSKEventOwner) throws {
        let fingerprint = try fingerprint(owner)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        try store.remove("restart-capability-" + fingerprint + ".json")
        try store.remove("restart-material-" + fingerprint + ".json")
        try store.remove("stage-consent-" + fingerprint + ".json")
        // The metadata-only source replay fence survives logout/private-secret
        // cleanup. Only new explicit signed normal admission removes it.

    }
    static func randomCapability() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct SourceRestorationFence: Codable, Equatable {
        let schema: Int
        let namespace: String
        let ownerFingerprint: String
        let original: NativeProtectedReplacementCoordinator.RestartIntent
        let journalIntent: NativeProtectedReplacementCoordinator.RestartIntent
        let materialSHA256: String
    }
    @MainActor
    func markSourceRestoration(owner: NativePushPSKEventOwner, material: Material,
        journalIntent: NativeProtectedReplacementCoordinator.RestartIntent) throws {
        guard try loadMaterial(owner: owner) == material, journalIntent.isValid,
              journalIntent.transactionID == material.intent.transactionID,
              journalIntent.sourceSHA256 == material.intent.sourceSHA256,
              journalIntent.candidateSHA256 == material.intent.candidateSHA256,
              journalIntent.generation == material.intent.generation,
              journalIntent.processInstanceID == NativeProtectedReplacementCoordinator.processInstanceID,
              journalIntent.ownerTokenSHA256 != material.intent.ownerTokenSHA256 else { throw Failure.mismatch }
        let value = SourceRestorationFence(schema: 1, namespace: "vex-protected-source-restoration-v1",
            ownerFingerprint: try fingerprint(owner), original: material.intent,
            journalIntent: journalIntent, materialSHA256: try materialDigest(material))
        let data = try encode(value, limit: 16_384), name = "source-restoration-" + value.ownerFingerprint + ".json"
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        if let old = try store.read(name) { guard old == data else { throw Failure.mismatch }; return }
        try store.write(data, name: name); guard try store.read(name) == data else { throw Failure.unavailable }
    }
    func sourceRestorationFence(owner: NativePushPSKEventOwner) throws -> SourceRestorationFence? {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        guard let data = try store.read("source-restoration-" + fingerprint(owner) + ".json") else { return nil }
        guard let value = try? JSONDecoder().decode(SourceRestorationFence.self, from: data),
              value.schema == 1, value.namespace == "vex-protected-source-restoration-v1",
              value.ownerFingerprint == (try fingerprint(owner)), value.original.isValid, value.journalIntent.isValid,
              value.original.transactionID == value.journalIntent.transactionID,
              value.original.sourceSHA256 == value.journalIntent.sourceSHA256,
              value.original.candidateSHA256 == value.journalIntent.candidateSHA256,
              value.original.generation == value.journalIntent.generation,
              value.original.ownerTokenSHA256 != value.journalIntent.ownerTokenSHA256,
              NativeProtectedReplacementCoordinator.validDigest(value.materialSHA256),
              (try? encode(value, limit: 16_384)) == data else { throw Failure.mismatch }
        return value
    }
    /// Only after an explicit newly signed/current connect and root admission;
    /// never expiry, metadata, notification, warmup or startup reconciliation.
    func removeSourceRestorationFence(owner: NativePushPSKEventOwner, expected: SourceRestorationFence) throws {
        guard try sourceRestorationFence(owner: owner) == expected else { throw Failure.mismatch }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        let name = "source-restoration-" + (try fingerprint(owner)) + ".json"
        try store.remove(name); guard try store.read(name) == nil else { throw Failure.unavailable }
    }

}

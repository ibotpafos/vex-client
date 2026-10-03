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
        // Immutable provenance written with the nonce, before purpose/capability.
        // nil preserves the exact canonical encoding of legacy journal material.
        var stagePurposeRequired: Bool? = nil
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
    /// Metadata-only private retirement WAL. The ACK digest records local
    /// custody, NOT root authority, a journal, a receipt, TTL or admission.
    struct StageCancellationRetirement: Codable, Equatable {
        let schema: Int
        let namespace: String
        let stage: StageConsent
        let stageSHA256: String
        let acknowledgementSHA256: String
        let capabilitySHA256: String?
        let phase: String
    }
    enum Failure: LocalizedError {
        case unavailable, mismatch, expired
        var errorDescription: String? { "Защищённое восстановление не подтверждено. Данные сохранены для явного повтора." }
    }
    private let root: URL
    // Package-internal deterministic IO boundary seam; production defaults to
    // nil. It receives no identity, secret, file path or authority payload.
    private let afterRetirementStep: ((String) throws -> Void)?
    init(fileManager: FileManager = .default, appDataURL: URL? = nil,
        afterRetirementStep: ((String) throws -> Void)? = nil) {
        root = appDataURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("VEX Native", isDirectory: true)
        self.afterRetirementStep = afterRetirementStep
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
        sourceConfig: String, candidateConfig: String, selectedLocationID: String, targetLocationID: String,
        requiresStageConsent: Bool = false) throws {
        let value = Material(schema: 1, namespace: "vex-protected-restart-material-v1",
            ownerFingerprint: try fingerprint(owner), intent: intent, rotationID: rotationID,
            source: record(source), candidate: record(candidate), sourceConfig: sourceConfig,
            candidateConfig: candidateConfig, selectedLocationID: selectedLocationID, targetLocationID: targetLocationID,
            stagePurposeRequired: requiresStageConsent ? true : nil)
        let data = try encode(value, limit: 1_048_576)
        _ = try decodeMaterial(data, owner: owner)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        try store.ensureDirectory(); let name = "restart-material-" + value.ownerFingerprint + ".json"
        try requireNotRetired(owner: owner, material: value)
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
              value.stagePurposeRequired == nil || value.stagePurposeRequired == true,
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
        if let retirement = try stageCancellationRetirement(owner: owner), retirement.stage.intent == material.intent {
            try requireRetirementMaterial(retirement, material: material, owner: owner)
            guard try loadMaterial(owner: owner) == material else { throw Failure.mismatch }
            let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
            if let data = try store.read("stage-consent-" + fingerprint(owner) + ".json") {
                guard data == (try encode(retirement.stage, limit: 16_384)) else { throw Failure.mismatch }
            }
            return retirement.stage // cancellation custody, never authorization
        }
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
        try requireNotRetired(owner: owner, material: material)
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
        try requireNotRetired(owner: owner, material: material)
        guard try loadMaterial(owner: owner) == material, now > 0, now < 9_000_000_000 else { throw Failure.mismatch }
        let purpose = try stageConsent(owner: owner, material: material)
        guard purpose?.cancelled != true, material.stagePurposeRequired != true || purpose != nil else { throw Failure.mismatch }
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
        if let retirement = try stageCancellationRetirement(owner: owner), retirement.phase == "retiring" || retirement.stage.intent.transactionID == material.intent.transactionID {
            // A partially removed capability is private cleanup input only.
            // Never expose it to adoption, journal continuation or renewal.
            guard try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
                .read("restart-capability-" + fingerprint(owner) + ".json") == nil else { throw Failure.mismatch }
            return nil
        }
        return try privateCapability(owner: owner, material: material)
    }
    private func privateCapability(owner: NativePushPSKEventOwner, material: Material) throws -> Capability? {
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
    @MainActor
    func removeMaterial(owner: NativePushPSKEventOwner, expected: Material) throws {
        if let retirement = try stageCancellationRetirement(owner: owner), retirement.stage.intent == expected.intent {
            try requireRetirementMaterial(retirement, material: expected, owner: owner)
            try finishStageCancellation(owner: owner, expected: retirement, isCurrent: { true }); return
        }
        guard try loadMaterial(owner: owner) == expected,
              try loadCapability(owner: owner, material: expected) == nil else { throw Failure.mismatch }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        // Validate the purpose record before either deletion; it carries no raw
        // capability and is removed only with the exact proved/cancelled material.
        if let stage = try stageConsent(owner: owner, material: expected), stage.cancelled {
            let retirement = try beginStageCancellation(owner: owner, material: expected, isCurrent: { true })
            try finishStageCancellation(owner: owner, expected: retirement, isCurrent: { true }); return
        }
        // TODO(post-promotion-retirement): non-cancellation receipt/source cleanup
        // still needs its own durable terminal evidence across both deletions.
        // A required missing purpose cannot create a new capability meanwhile.
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
        // Metadata-only cancellation retirement and source replay fences survive
        // logout/private-secret cleanup. Neither absence nor purge grants consent.

    }
    static func randomCapability() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func retirementName(_ owner: NativePushPSKEventOwner) throws -> String {
        "stage-retirement-" + (try fingerprint(owner)) + ".json"
    }
    private func metadataDigest<T: Encodable>(_ value: T) throws -> String {
        NativeProtectedReplacementCoordinator.digest(String(decoding: try encode(value, limit: 16_384), as: UTF8.self))
    }
    func stageCancellationRetirement(owner: NativePushPSKEventOwner) throws -> StageCancellationRetirement? {
        guard let data = try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384).read(retirementName(owner)) else { return nil }
        guard let value = try? JSONDecoder().decode(StageCancellationRetirement.self, from: data),
              value.schema == 1, value.namespace == "vex-protected-stage-retirement-v1",
              value.stage.schema == 1, value.stage.namespace == "vex-protected-stage-consent-v1",
              value.stage.ownerFingerprint == (try fingerprint(owner)), value.stage.intent.isValid, value.stage.cancelled,
              NativeProtectedReplacementCoordinator.validDigest(value.stage.materialSHA256),
              value.stageSHA256 == (try metadataDigest(value.stage)),
              value.acknowledgementSHA256 == NativeProtectedReplacementCoordinator.digest("stage-cancelled transaction_id=\(value.stage.intent.transactionID)\n"),
              value.capabilitySHA256.map(NativeProtectedReplacementCoordinator.validDigest) ?? true,
              ["retiring", "retired"].contains(value.phase), (try? encode(value, limit: 16_384)) == data else { throw Failure.mismatch }
        return value
    }
    private func requireNotRetired(owner: NativePushPSKEventOwner, material: Material) throws {
        if let value = try stageCancellationRetirement(owner: owner) {
            guard value.phase == "retired", value.stage.intent.transactionID != material.intent.transactionID,
                  value.stage.materialSHA256 != (try materialDigest(material)) else { throw Failure.mismatch }
        }
    }
    private func requireRetirementMaterial(_ value: StageCancellationRetirement, material: Material,
        owner: NativePushPSKEventOwner) throws {
        guard value.stage.ownerFingerprint == (try fingerprint(owner)), value.stage.intent == material.intent,
              value.stage.materialSHA256 == (try materialDigest(material)) else { throw Failure.mismatch }
    }
    private func retirementStep(_ step: String, isCurrent: () -> Bool) throws {
        guard !Task.isCancelled, isCurrent() else { throw Failure.mismatch }
        try afterRetirementStep?(step)
        guard !Task.isCancelled, isCurrent() else { throw Failure.mismatch }
    }
    /// WAL precedes every deletion. Existing exact WAL is reused byte-for-byte;
    /// a legacy cancelled marker can migrate only while exact material remains.
    func beginStageCancellation(owner: NativePushPSKEventOwner, material: Material,
        isCurrent: () -> Bool) throws -> StageCancellationRetirement {
        try retirementStep("before-retirement-write", isCurrent: isCurrent)
        guard try loadMaterial(owner: owner) == material else { throw Failure.mismatch }
        let existing = try stageCancellationRetirement(owner: owner)
        if let existing, existing.stage.intent == material.intent {
            try requireRetirementMaterial(existing, material: material, owner: owner); return existing
        }
        guard existing == nil || existing?.phase == "retired",
              let stage = try stageConsent(owner: owner, material: material), stage.cancelled else { throw Failure.mismatch }
        let capability = try privateCapability(owner: owner, material: material)
        let value = StageCancellationRetirement(schema: 1, namespace: "vex-protected-stage-retirement-v1", stage: stage,
            stageSHA256: try metadataDigest(stage),
            acknowledgementSHA256: NativeProtectedReplacementCoordinator.digest("stage-cancelled transaction_id=\(material.intent.transactionID)\n"),
            capabilitySHA256: try capability.map { try metadataDigest($0) }, phase: "retiring")
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        guard try stageCancellationRetirement(owner: owner) == existing,
              try stageConsent(owner: owner, material: material) == stage,
              try privateCapability(owner: owner, material: material) == capability else { throw Failure.mismatch }
        try store.write(encode(value, limit: 16_384), name: retirementName(owner))
        try retirementStep("after-retirement-write", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == value else { throw Failure.unavailable }
        try retirementStep("after-retirement-readback", isCurrent: isCurrent); return value
    }
    /// Raw capability is never returned. Missing files are allowed only under
    /// this exact WAL, not as evidence that root cancelled or committed anything.
    func removeCancelledCapability(owner: NativePushPSKEventOwner, expected: StageCancellationRetirement,
        isCurrent: () -> Bool) throws {
        try retirementStep("before-capability-remove", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == expected else { throw Failure.mismatch }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384), name = "restart-capability-" + (try fingerprint(owner)) + ".json"
        if let bytes = try store.read(name) {
            guard NativeProtectedReplacementCoordinator.digest(String(decoding: bytes, as: UTF8.self)) == expected.capabilitySHA256 else { throw Failure.mismatch }
            try store.remove(name)
        }
        try retirementStep("after-capability-remove", isCurrent: isCurrent)
        guard try store.read(name) == nil, try stageCancellationRetirement(owner: owner) == expected else { throw Failure.unavailable }
    }
    /// Caller first removes only the exact unconsumed current-process nonce.
    /// Root journals/receipts and source fences are deliberately not touched.
    func validateStageCancellationCustody(owner: NativePushPSKEventOwner, expected: StageCancellationRetirement) throws {
        guard try stageCancellationRetirement(owner: owner) == expected else { throw Failure.mismatch }
        if let material = try loadMaterial(owner: owner) { try requireRetirementMaterial(expected, material: material, owner: owner) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 16_384)
        if let bytes = try store.read("stage-consent-" + fingerprint(owner) + ".json") {
            guard bytes == (try encode(expected.stage, limit: 16_384)) else { throw Failure.mismatch }
        }
        if let bytes = try store.read("restart-capability-" + fingerprint(owner) + ".json") {
            guard NativeProtectedReplacementCoordinator.digest(String(decoding: bytes, as: UTF8.self)) == expected.capabilitySHA256 else { throw Failure.mismatch }
        }
    }
    private func requireCancelledFilesAbsent(owner: NativePushPSKEventOwner) throws {
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576), fp = try fingerprint(owner)
        guard try store.read("restart-material-" + fp + ".json") == nil,
              try store.read("stage-consent-" + fp + ".json") == nil,
              try store.read("restart-capability-" + fp + ".json") == nil else { throw Failure.unavailable }
    }
    @MainActor
    func finishStageCancellation(owner: NativePushPSKEventOwner, expected: StageCancellationRetirement,
        isCurrent: () -> Bool) throws {
        guard expected.stage.intent.processInstanceID == NativeProtectedReplacementCoordinator.processInstanceID,
              try stageCancellationRetirement(owner: owner) == expected,
              try !NativeProtectedPromotionStore(appDataURL: root).hasRecord(accountID: owner.accountID,
                installationID: owner.installationID) else { throw Failure.mismatch }
        try validateStageCancellationCustody(owner: owner, expected: expected)
        try removeCancelledCapability(owner: owner, expected: expected, isCurrent: isCurrent)
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: 1_048_576)
        let purpose = "stage-consent-" + (try fingerprint(owner)) + ".json", materialName = "restart-material-" + (try fingerprint(owner)) + ".json"
        if let material = try loadMaterial(owner: owner) { try requireRetirementMaterial(expected, material: material, owner: owner) }
        try retirementStep("before-purpose-remove", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == expected else { throw Failure.mismatch }
        if let bytes = try store.read(purpose) {
            guard bytes == (try encode(expected.stage, limit: 16_384)) else { throw Failure.mismatch }; try store.remove(purpose)
        }
        try retirementStep("after-purpose-remove", isCurrent: isCurrent)
        guard try store.read(purpose) == nil else { throw Failure.unavailable }
        try retirementStep("before-material-remove", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == expected else { throw Failure.mismatch }
        try validateStageCancellationCustody(owner: owner, expected: expected)
        if let material = try loadMaterial(owner: owner) {
            try requireRetirementMaterial(expected, material: material, owner: owner); try store.remove(materialName)
        }
        try retirementStep("after-material-remove", isCurrent: isCurrent)
        guard try store.read(materialName) == nil, try store.read(purpose) == nil,
              try NativePushSecureFileStore(rootURL: root, maxBytes: 16_384).read("restart-capability-" + fingerprint(owner) + ".json") == nil else { throw Failure.unavailable }
        try retirementStep("before-retired-write", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == expected else { throw Failure.mismatch }
        try requireCancelledFilesAbsent(owner: owner)
        let retired = StageCancellationRetirement(schema: expected.schema, namespace: expected.namespace, stage: expected.stage,
            stageSHA256: expected.stageSHA256, acknowledgementSHA256: expected.acknowledgementSHA256,
            capabilitySHA256: expected.capabilitySHA256, phase: "retired")
        if expected.phase != "retired" { try store.write(encode(retired, limit: 16_384), name: retirementName(owner)) }
        try retirementStep("after-retired-write", isCurrent: isCurrent)
        guard try stageCancellationRetirement(owner: owner) == retired else { throw Failure.unavailable }
        try requireCancelledFilesAbsent(owner: owner)
        try retirementStep("after-retired-readback", isCurrent: isCurrent)
        try requireCancelledFilesAbsent(owner: owner)
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

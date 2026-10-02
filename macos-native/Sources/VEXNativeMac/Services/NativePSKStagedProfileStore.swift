import CryptoKit
import Foundation

/// Durable, inactive ManagedVpnProfile PSK staging only.  This type has no activation,
/// helper, queue, API, or acknowledgement side effects.
struct NativePSKStagedProfileStore {
    struct Record: Codable, Equatable {
        let schema: Int
        let namespace: String
        let ownerFingerprint: String
        let managedDeviceID: String
        let rotationID: String
        let envelope: PSKRotationCurrentResponse
        let stagedAt: Date
    }

    private struct OwnerIndex: Codable { let schema: Int; let namespace: String; let ownerFingerprint: String; let tuples: [Tuple] }
    private struct Tuple: Codable, Hashable { let managedDeviceID: String; let rotationID: String }
    private let root: URL
    private static let maxBytes = 1_048_576
    private static let schema = 1
    private static let namespace = "native-psk-staged-profile-v1"
    private static let indexNamespace = "native-psk-staged-profile-index-v1"
    private static let maxTuples = 32
    private static let maxIndexBytes = 65_536

    init(fileManager: FileManager = .default, appDataURL: URL? = nil) {
        root = appDataURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("VEX Native", isDirectory: true)
    }

    func stage(_ envelope: PSKRotationCurrentResponse, owner: NativePushPSKEventOwner, managedDeviceID: String, stagedAt: Date = Date()) throws {
        guard valid(owner), NativePSKIdentifier.device(managedDeviceID), validEnvelope(envelope, managedDeviceID: managedDeviceID), stagedAt.timeIntervalSinceReferenceDate.isFinite else { throw CocoaError(.fileWriteInvalidFileName) }
        var sanitized = envelope
        sanitized.profile.config = nil
        let record = Record(schema: Self.schema, namespace: Self.namespace, ownerFingerprint: fingerprint(owner), managedDeviceID: managedDeviceID, rotationID: envelope.rotationID, envelope: sanitized, stagedAt: stagedAt)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes)
        try store.ensureDirectory()
        let name = fileName(owner: owner, managedDeviceID: managedDeviceID, rotationID: envelope.rotationID)
        // Validate before replacing.  A corrupt/oversized/tampered existing stage is evidence,
        // not disposable data; preserve it for recovery rather than silently overwriting it.
        var exactReplay = false
        if let existingData = try store.read(name) {
            let existing = try decodeValidated(existingData, owner: owner, managedDeviceID: managedDeviceID, rotationID: envelope.rotationID)
            if existing.envelope == sanitized { exactReplay = true } else {
                guard record.envelope.profileVersion > existing.envelope.profileVersion,
                      record.stagedAt >= existing.stagedAt else { throw CocoaError(.fileWriteFileExists) }
            } // exact replay still records a missing index tuple before its idempotent rewrite
        }
        // Index first: a crash after secret write must never make cleanup lose the tuple.
        var index = try loadIndex(owner: owner, store: store)
        let tuple = Tuple(managedDeviceID: managedDeviceID, rotationID: envelope.rotationID)
        if !index.tuples.contains(tuple) {
            guard index.tuples.count < Self.maxTuples else { throw CocoaError(.fileWriteOutOfSpace) }
            index = OwnerIndex(schema: Self.schema, namespace: Self.indexNamespace, ownerFingerprint: fingerprint(owner), tuples: (index.tuples + [tuple]).sorted { ($0.managedDeviceID, $0.rotationID) < ($1.managedDeviceID, $1.rotationID) })
            try writeIndex(index, owner: owner, store: store)
        }
        if exactReplay { return }
        try store.write(data, name: name)
    }

    func load(owner: NativePushPSKEventOwner, managedDeviceID: String, rotationID: String) throws -> Record? {
        guard valid(owner), NativePSKIdentifier.device(managedDeviceID), NativePSKIdentifier.rotation(rotationID) else { throw CocoaError(.fileReadInvalidFileName) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes)
        try store.ensureDirectory()
        guard let data = try store.read(fileName(owner: owner, managedDeviceID: managedDeviceID, rotationID: rotationID)) else { return nil }
        return try decodeValidated(data, owner: owner, managedDeviceID: managedDeviceID, rotationID: rotationID)
    }

    /// Removes only the exact owned stage; never enumerates neighbouring ownership namespaces.
    func purge(owner: NativePushPSKEventOwner, managedDeviceID: String, rotationID: String) throws {
        guard valid(owner), NativePSKIdentifier.device(managedDeviceID), NativePSKIdentifier.rotation(rotationID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes)
        try store.remove(fileName(owner: owner, managedDeviceID: managedDeviceID, rotationID: rotationID))
        var index = try loadIndex(owner: owner, store: store)
        index = OwnerIndex(schema: Self.schema, namespace: Self.indexNamespace, ownerFingerprint: fingerprint(owner), tuples: index.tuples.filter { !($0.managedDeviceID == managedDeviceID && $0.rotationID == rotationID) })
        try writeIndex(index, owner: owner, store: store)
    }

    func purgeAll(owner: NativePushPSKEventOwner) throws {
        guard valid(owner) else { throw CocoaError(.fileWriteInvalidFileName) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes)
        let index = try loadIndex(owner: owner, store: store)
        for tuple in index.tuples { try store.remove(fileName(owner: owner, managedDeviceID: tuple.managedDeviceID, rotationID: tuple.rotationID)) }
        try store.remove(indexFileName(owner: owner))
    }


    private func indexFileName(owner: NativePushPSKEventOwner) -> String { "staged-index-" + fingerprint(owner) + ".json" }
    private func loadIndex(owner: NativePushPSKEventOwner, store: NativePushSecureFileStore) throws -> OwnerIndex {
        guard let data = try store.read(indexFileName(owner: owner)) else { return OwnerIndex(schema: Self.schema, namespace: Self.indexNamespace, ownerFingerprint: fingerprint(owner), tuples: []) }
        guard data.count <= Self.maxIndexBytes else { throw CocoaError(.fileReadCorruptFile) }
        let index: OwnerIndex; do { index = try JSONDecoder().decode(OwnerIndex.self, from: data) } catch { throw CocoaError(.fileReadCorruptFile) }
        guard index.schema == Self.schema, index.namespace == Self.indexNamespace, index.ownerFingerprint == fingerprint(owner), index.tuples.count <= Self.maxTuples, Set(index.tuples).count == index.tuples.count, index.tuples.allSatisfy({ NativePSKIdentifier.device($0.managedDeviceID) && NativePSKIdentifier.rotation($0.rotationID) }) else { throw CocoaError(.fileReadCorruptFile) }
        return index
    }
    private func writeIndex(_ index: OwnerIndex, owner: NativePushPSKEventOwner, store: NativePushSecureFileStore) throws {
        let data = try JSONEncoder().encode(index); guard data.count <= Self.maxIndexBytes else { throw CocoaError(.fileWriteOutOfSpace) }; try store.write(data, name: indexFileName(owner: owner))
    }

    private func decodeValidated(_ data: Data, owner: NativePushPSKEventOwner, managedDeviceID: String, rotationID: String) throws -> Record {
        guard data.count <= Self.maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "namespace", "ownerFingerprint", "managedDeviceID", "rotationID", "envelope", "stagedAt"],
              !containsSensitiveOrUnknownProfileData(object) else { throw CocoaError(.fileReadCorruptFile) }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) } catch { throw CocoaError(.fileReadCorruptFile) }
        guard record.schema == Self.schema, record.namespace == Self.namespace,
              record.ownerFingerprint == fingerprint(owner), record.managedDeviceID == managedDeviceID,
              record.rotationID == rotationID, record.stagedAt.timeIntervalSinceReferenceDate.isFinite,
              validEnvelope(record.envelope, managedDeviceID: managedDeviceID),
              record.envelope.rotationID == rotationID, record.envelope.profile.config == nil else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    /// Codable intentionally ignores unknown keys; reject them where they could smuggle opaque secrets.
    private func containsSensitiveOrUnknownProfileData(_ object: [String: Any]) -> Bool {
        guard let envelope = object["envelope"] as? [String: Any],
              Set(envelope.keys) == ["rotation_id", "activate", "current_version", "profile_version", "profile_digest", "deadline_at", "profile"],
              let profile = envelope["profile"] as? [String: Any] else { return true }
        let forbidden = ["config", "private", "session", "push", "token", "credential"]
        guard !profile.keys.contains(where: { key in forbidden.contains { key.lowercased().contains($0) } }) else { return true }
        if let authorization = profile["authorization"] as? [String: Any] {
            guard Set(authorization.keys) == ["algorithm", "key_id", "payload_base64", "signature_base64"],
                  let algorithm = authorization["algorithm"] as? String,
                  let keyID = authorization["key_id"] as? String,
                  let payload = authorization["payload_base64"] as? String,
                  let signature = authorization["signature_base64"] as? String,
                  validAuthorization(algorithm: algorithm, keyID: keyID, payload: payload, signature: signature) else { return true }
        } else if profile["authorization"] != nil { return true }
        return false
    }

    private func fileName(owner: NativePushPSKEventOwner, managedDeviceID: String, rotationID: String) -> String { "staged-" + digest(lengthPrefixed([fingerprint(owner), managedDeviceID, rotationID])) + ".json" }
    private func fingerprint(_ owner: NativePushPSKEventOwner) -> String { digest(lengthPrefixed([owner.accountID, owner.installationID])) }
    private func lengthPrefixed(_ values: [String]) -> Data { var output = Data(); for value in values { let bytes = Data(value.utf8); var length = UInt64(bytes.count).bigEndian; withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }; output.append(bytes) }; return output }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func valid(_ owner: NativePushPSKEventOwner) -> Bool { NativePushPSKEventOwner(accountID: owner.accountID, installationID: owner.installationID) == owner }
    private func validUUID(_ value: String) -> Bool { guard let uuid = UUID(uuidString: value) else { return false }; return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame }
    private func validDate(_ value: String) -> Bool { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]; return (f.date(from: value) ?? standard.date(from: value))?.timeIntervalSinceReferenceDate.isFinite == true }
    private func validPSK(_ value: String?) -> Bool { guard let value, value.utf8.count <= 128, let data = Data(base64Encoded: value), data.count == 32 else { return false }; return data.base64EncodedString() == value }
    private func validAuthorization(algorithm: String, keyID: String, payload: String, signature: String) -> Bool {
        guard algorithm == "ECDSA_P256_SHA256_DER", keyID.utf8.count > 0, keyID.utf8.count <= 128,
              keyID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              let payloadBytes = rawBase64URL(payload, limit: 65_536),
              let signatureBytes = rawBase64URL(signature, limit: 128),
              !payloadBytes.isEmpty, validP256DERSignature(signatureBytes) else { return false }
        return true
    }
    private func validP256DERSignature(_ bytes: Data) -> Bool {
        let b = [UInt8](bytes)
        guard (8...80).contains(b.count), b[0] == 0x30, Int(b[1]) == b.count - 2 else { return false }
        var index = 2
        func integer() -> Bool {
            guard index + 2 <= b.count, b[index] == 0x02 else { return false }
            let length = Int(b[index + 1]); index += 2
            guard length > 0, index + length <= b.count, b[index] & 0x80 == 0 else { return false }
            if length > 1, b[index] == 0, b[index + 1] & 0x80 == 0 { return false }
            index += length; return true
        }
        return integer() && integer() && index == b.count
    }
    private func rawBase64URL(_ value: String, limit: Int) -> Data? {
        guard !value.isEmpty, value.utf8.count <= limit,
              value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else { return nil }
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded) else { return nil }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value ? bytes : nil
    }
    private func validEnvelope(_ value: PSKRotationCurrentResponse, managedDeviceID: String) -> Bool {
        guard !value.activate, value.currentVersion > 0, value.profileVersion > value.currentVersion, NativePSKIdentifier.rotation(value.rotationID), validDate(value.deadlineAt), value.profile.version == value.profileVersion, value.profile.deviceId == managedDeviceID, value.profile.revoked != true, value.profile.unchanged != true, validPSK(value.profile.presharedKey), value.profile.config == nil, value.profile.authorization.map({ validAuthorization(algorithm: $0.algorithm, keyID: $0.keyID, payload: $0.payloadBase64, signature: $0.signatureBase64) }) ?? true else { return false }
        let prefix = "sha256:"; let digest = value.profileDigest
        guard digest.hasPrefix(prefix), digest.utf8.count == prefix.utf8.count + 64 else { return false }
        return digest.dropFirst(prefix.count).utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }
}

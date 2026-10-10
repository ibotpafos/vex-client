import Foundation
import CryptoKit

struct VEXVpnDeviceScope: Codable, Equatable {
    var installationId: String
    var externalDeviceId: String
    var registrationConfirmationPending = false

    private enum CodingKeys: String, CodingKey {
        case installationId, externalDeviceId, registrationConfirmationPending
    }

    init(installationId: String, externalDeviceId: String, registrationConfirmationPending: Bool = false) {
        self.installationId = installationId
        self.externalDeviceId = externalDeviceId
        self.registrationConfirmationPending = registrationConfirmationPending
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        installationId = try fields.decode(String.self, forKey: .installationId)
        externalDeviceId = try fields.decode(String.self, forKey: .externalDeviceId)
        registrationConfirmationPending = try fields.decodeIfPresent(Bool.self, forKey: .registrationConfirmationPending) ?? true
    }
}

struct VEXDeviceIdentityStore {
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: any VEXDeviceIdentityKeychain
    private let deviceIdKey = "vex.auth.device_id"
    private let identityKey = "vex.auth.device_identity.v1"
    private let nativePrefix = "vexd_"
    private let legacyNativePrefix = "macos-native-"

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: any VEXDeviceIdentityKeychain = VEXKeychainStore()
    ) {
        self.fileStore = fileStore
        self.nativeKeychain = nativeKeychain
    }

    func getOrCreateDeviceId() -> String {
        if let existing = fileStore.string(for: deviceIdKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isNativeManagedDeviceId(existing) {
            return existing
        }
        if let existing = nativeKeychain.string(for: deviceIdKey, allowAuthenticationUI: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isNativeManagedDeviceId(existing) {
            try? fileStore.setString(existing, for: deviceIdKey)
            return existing
        }
        let created = "\(nativePrefix)\(UUID().uuidString.lowercased())"
        try? fileStore.setString(created, for: deviceIdKey)
        return created
    }

    func legacyDeviceId() throws -> String? {
        let existing = try fileStore.stringIfPresent(for: deviceIdKey)
            ?? nativeKeychain.stringIfPresent(for: deviceIdKey, allowAuthenticationUI: false)
        guard let existing else { return nil }
        let normalized = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNativeManagedDeviceId(normalized), !normalized.contains(":") else { throw VEXKeychainError.invalidValue }
        return normalized
    }

    func scopedDeviceScope(accountUserId: String) throws -> VEXVpnDeviceScope? {
        let key = try VPNAccountScope.storageKey(deviceIdKey, accountUserId: accountUserId)
        guard let stored = try fileStore.stringIfPresent(for: key) else { return nil }
        let scope = try JSONDecoder().decode(VEXVpnDeviceScope.self, from: Data(stored.utf8))
        guard isNativeManagedDeviceId(scope.installationId), !scope.installationId.contains(":"),
              isNativeManagedDeviceId(scope.externalDeviceId), !scope.externalDeviceId.contains(":") else {
            throw VEXKeychainError.invalidValue
        }
        return scope
    }

    func getOrCreateDeviceScope(accountUserId: String, adoptingLegacyId: String? = nil,
                                registrationConfirmationPending: Bool = false) throws -> VEXVpnDeviceScope {
        if let existing = try scopedDeviceScope(accountUserId: accountUserId) { return existing }
        let created = adoptingLegacyId ?? "\(nativePrefix)\(UUID().uuidString.lowercased())"
        guard isNativeManagedDeviceId(created), !created.contains(":") else { throw VEXKeychainError.invalidValue }
        let scope = VEXVpnDeviceScope(installationId: created, externalDeviceId: created,
            registrationConfirmationPending: registrationConfirmationPending)
        try saveScope(scope, accountUserId: accountUserId)
        return scope
    }

    func repairLegacyInstallationScope(accountUserId: String, expectedInstallationId: String) throws -> VEXVpnDeviceScope {
        guard var scope = try scopedDeviceScope(accountUserId: accountUserId) else { throw VEXKeychainError.invalidValue }
        if scope.installationId != expectedInstallationId { return scope }
        scope.installationId = "\(nativePrefix)\(UUID().uuidString.lowercased())"
        scope.registrationConfirmationPending = true
        try saveScope(scope, accountUserId: accountUserId)
        return scope
    }

    func confirmDeviceScope(accountUserId: String, expectedInstallationId: String) throws {
        guard var scope = try scopedDeviceScope(accountUserId: accountUserId),
              scope.installationId == expectedInstallationId else { throw VEXKeychainError.invalidValue }
        guard scope.registrationConfirmationPending else { return }
        scope.registrationConfirmationPending = false
        try saveScope(scope, accountUserId: accountUserId)
    }

    private func saveScope(_ scope: VEXVpnDeviceScope, accountUserId: String) throws {
        let key = try VPNAccountScope.storageKey(deviceIdKey, accountUserId: accountUserId)
        let data = try JSONEncoder().encode(scope)
        guard let payload = String(data: data, encoding: .utf8) else { throw VEXKeychainError.invalidValue }
        try fileStore.setString(payload, for: key)
    }

    private func isNativeManagedDeviceId(_ value: String) -> Bool {
        value.hasPrefix(nativePrefix) || value.hasPrefix(legacyNativePrefix)
    }

    func getOrCreateDeviceIdentity() throws -> VEXDeviceIdentity {
        if let stored = loadDeviceIdentity() {
            return stored
        }
        let privateKey = P256.Signing.PrivateKey()
        let identity = try VEXDeviceIdentity(privateKeyRaw: privateKey.rawRepresentation)
        try nativeKeychain.setString(identity.encodedPrivateKey, for: identityKey, requiresBiometricAuthentication: false)
        return identity
    }

    private func loadDeviceIdentity() -> VEXDeviceIdentity? {
        guard let encoded = nativeKeychain.string(for: identityKey, allowAuthenticationUI: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? VEXDeviceIdentity(privateKeyRaw: data)
    }
}

struct VEXDeviceIdentity {
    static let keyType = "p256_jwk"
    static let trustLevel = "software_secure_store"
    static let payloadVersion = "vex-device-binding-v1"

    private let privateKey: P256.Signing.PrivateKey

    init(privateKeyRaw: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    var encodedPrivateKey: String {
        privateKey.rawRepresentation.base64EncodedString()
    }

    var publicKeyJWK: String {
        let raw = privateKey.publicKey.rawRepresentation
        let x = raw.prefix(32)
        let y = raw.dropFirst(32).prefix(32)
        let jwk: [String: String] = [
            "kty": "EC",
            "crv": "P-256",
            "x": Data(x).base64URLEncodedString(),
            "y": Data(y).base64URLEncodedString(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func signature(for payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return signature.rawRepresentation.base64URLEncodedString()
    }

    static func signaturePayload(
        challenge: DeviceIdentityChallenge,
        installationId: String,
        identityPublicKey: String,
        wireGuardPublicKey: String
    ) -> String {
        [
            payloadVersion,
            challenge.id.trimmingCharacters(in: .whitespacesAndNewlines),
            challenge.nonce.trimmingCharacters(in: .whitespacesAndNewlines),
            challenge.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            installationId.trimmingCharacters(in: .whitespacesAndNewlines),
            identityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            wireGuardPublicKey.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "\n")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

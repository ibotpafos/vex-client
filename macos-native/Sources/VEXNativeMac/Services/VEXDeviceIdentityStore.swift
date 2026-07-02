import Foundation
import CryptoKit

struct VEXDeviceIdentityStore {
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: VEXKeychainStore
    private let deviceIdKey = "vex.auth.device_id"
    private let identityKey = "vex.auth.device_identity.v1"
    private let nativePrefix = "vexd_"
    private let legacyNativePrefix = "macos-native-"

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: VEXKeychainStore = VEXKeychainStore()
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

    func getOrCreateDeviceIdentity() throws -> VEXDeviceIdentity {
        if let stored = loadDeviceIdentity() {
            return stored
        }
        let privateKey = P256.Signing.PrivateKey()
        let identity = try VEXDeviceIdentity(privateKeyRaw: privateKey.rawRepresentation)
        try nativeKeychain.setString(identity.encodedPrivateKey, for: identityKey)
        return identity
    }

    private func isNativeManagedDeviceId(_ value: String) -> Bool {
        value.hasPrefix(nativePrefix) || value.hasPrefix(legacyNativePrefix)
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

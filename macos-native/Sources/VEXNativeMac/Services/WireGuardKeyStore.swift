import CryptoKit
import Foundation

struct WireGuardKeyStore {
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: any VEXDeviceIdentityKeychain
    private let key = "vex.wireguard.keypair.v1"

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: any VEXDeviceIdentityKeychain = VEXKeychainStore()
    ) {
        self.fileStore = fileStore
        self.nativeKeychain = nativeKeychain
    }

    func getOrCreate() throws -> WireGuardKeyPair {
        if let existing = load() {
            return existing
        }
        let generated = generate(epoch: 1)
        try save(generated)
        return generated
    }

    func existing(accountUserId: String) throws -> WireGuardKeyPair? {
        let scopedKey = try VPNAccountScope.storageKey(key, accountUserId: accountUserId)
        guard let payload = try fileStore.stringIfPresent(for: scopedKey),
              let data = payload.data(using: .utf8) else { return nil }
        return try validatedKeyPair(JSONDecoder().decode(WireGuardKeyPair.self, from: data))
    }

    func getOrCreate(accountUserId: String, adoptingLegacyPublicKey: String? = nil) throws -> WireGuardKeyPair {
        if let existing = try existing(accountUserId: accountUserId) { return existing }
        let selected: WireGuardKeyPair
        if let adoptingLegacyPublicKey, !adoptingLegacyPublicKey.isEmpty,
           let legacy = try legacyKeyPair(), legacy.publicKey == adoptingLegacyPublicKey {
            let ownerKey = "\(key).legacy_owner.v1"
            let owner = try fileStore.stringIfPresent(for: ownerKey)
            if let owner, owner.isEmpty { throw VEXKeychainError.invalidValue }
            if owner == nil || owner == accountUserId {
                if owner == nil { try fileStore.setString(accountUserId, for: ownerKey) }
                selected = legacy
            } else {
                selected = generate(epoch: 1)
            }
        } else {
            selected = generate(epoch: 1)
        }
        try save(selected, accountUserId: accountUserId)
        return selected
    }

    private func legacyKeyPair() throws -> WireGuardKeyPair? {
        let payload = try fileStore.stringIfPresent(for: key)
            ?? nativeKeychain.stringIfPresent(for: key, allowAuthenticationUI: false)
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try validatedKeyPair(JSONDecoder().decode(WireGuardKeyPair.self, from: data))
    }

    func rotate(accountUserId: String, previousEpoch: Int? = nil) throws -> WireGuardKeyPair {
        let currentEpoch = try existing(accountUserId: accountUserId)?.keyEpoch
        let previous = previousEpoch ?? currentEpoch ?? 0
        guard previous >= 0, previous < Int.max - 1 else { throw VEXKeychainError.invalidValue }
        let generated = generate(epoch: max(previous + 1, 1))
        try save(generated, accountUserId: accountUserId)
        return generated
    }

    func save(_ keyPair: WireGuardKeyPair, accountUserId: String) throws {
        let scopedKey = try VPNAccountScope.storageKey(key, accountUserId: accountUserId)
        try save(validatedKeyPair(keyPair), storageKey: scopedKey)
    }

    func rotate(previousEpoch: Int? = nil) throws -> WireGuardKeyPair {
        let generated = generate(epoch: max((previousEpoch ?? load()?.keyEpoch ?? 0) + 1, 1))
        try save(generated)
        return generated
    }

    func save(_ keyPair: WireGuardKeyPair) throws {
        try save(keyPair, storageKey: key)
    }

    private func save(_ keyPair: WireGuardKeyPair, storageKey: String) throws {
        let data = try JSONEncoder().encode(keyPair)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try fileStore.setString(payload, for: storageKey)
    }

    func reset() throws {
        try fileStore.delete(key)
    }

    private func load() -> WireGuardKeyPair? {
        if let keyPair = loadFromFile() {
            return keyPair
        }
        if let keyPair = loadFromNativeKeychainSilently() {
            try? save(keyPair)
            return keyPair
        }
        return nil
    }

    private func loadFromFile() -> WireGuardKeyPair? {
        guard let payload = fileStore.string(for: key),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WireGuardKeyPair.self, from: data)
    }

    private func loadFromNativeKeychainSilently() -> WireGuardKeyPair? {
        guard let payload = nativeKeychain.string(for: key, allowAuthenticationUI: false),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WireGuardKeyPair.self, from: data)
    }

    private func validatedKeyPair(_ pair: WireGuardKeyPair) throws -> WireGuardKeyPair {
        guard pair.keyEpoch > 0, pair.keyEpoch < Int.max,
              let privateKey = Data(base64Encoded: pair.privateKey), privateKey.count == 32,
              let publicKey = Data(base64Encoded: pair.publicKey), publicKey.count == 32,
              publicKeyMatches(privateKey: privateKey, publicKey: publicKey) else { throw VEXKeychainError.invalidValue }
        return pair
    }

    private func generate(epoch: Int) -> WireGuardKeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return WireGuardKeyPair(
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            keyEpoch: epoch
        )
    }

    private func publicKeyMatches(privateKey: Data, publicKey: Data) -> Bool {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation) == publicKey
    }
}

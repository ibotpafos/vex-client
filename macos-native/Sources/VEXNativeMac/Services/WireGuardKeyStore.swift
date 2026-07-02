import CryptoKit
import Foundation

struct WireGuardKeyStore {
    private let fileStore: AppSensitiveFileStore
    private let nativeKeychain: VEXKeychainStore
    private let key = "vex.wireguard.keypair.v1"

    init(
        fileStore: AppSensitiveFileStore = AppSensitiveFileStore(),
        nativeKeychain: VEXKeychainStore = VEXKeychainStore()
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

    func rotate(previousEpoch: Int? = nil) throws -> WireGuardKeyPair {
        let generated = generate(epoch: max((previousEpoch ?? load()?.keyEpoch ?? 0) + 1, 1))
        try save(generated)
        return generated
    }

    func save(_ keyPair: WireGuardKeyPair) throws {
        let data = try JSONEncoder().encode(keyPair)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try fileStore.setString(payload, for: key)
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

    private func generate(epoch: Int) -> WireGuardKeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return WireGuardKeyPair(
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            keyEpoch: epoch
        )
    }
}

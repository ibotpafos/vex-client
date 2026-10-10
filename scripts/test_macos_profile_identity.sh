#!/usr/bin/env bash
# Exercise the production API/profile/cache flow without AppKit or live secure
# stores. CryptoKit/keychain identity generation and DNS are isolated below;
# full macOS package CI still compiles and tests their production implementations.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-profile-identity.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
source_dir="$harness_dir/Sources/VEXNativeMac"
test_dir="$harness_dir/Tests/VEXNativeMacTests"
mkdir -p "$source_dir" "$test_dir"
native_dir="$root_dir/macos-native/Sources/VEXNativeMac"
cp "$native_dir/Models/VEXModels.swift" "$source_dir/"
for name in VPNProfileCache VPNProfileCacheIdentity AppSensitiveFileStore NativeAwgBoolean VEXAPITransport; do
    cp "$native_dir/Services/$name.swift" "$source_dir/"
done
{
    printf '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
    cat "$native_dir/Services/VEXAPIClient.swift"
} > "$source_dir/VEXAPIClient.swift"
awk '/^enum IPv4Resolver/ { exit } { print }' "$native_dir/Services/VPNProfileService.swift" > "$source_dir/VPNProfileService.swift"
awk '/^import CryptoKit/ { next } /    private func generate\(epoch:/ { exit } { print }' "$native_dir/Services/WireGuardKeyStore.swift" > "$source_dir/WireGuardKeyStore.swift"
cat >> "$source_dir/WireGuardKeyStore.swift" <<'SWIFT'
    private func generate(epoch: Int) -> WireGuardKeyPair {
        fatalError("Profile identity fixtures must supply an isolated key pair")
    }
}
SWIFT
cat > "$source_dir/IsolatedPlatformStores.swift" <<'SWIFT'
import Foundation
enum VEXKeychainError: Error { case invalidValue }
struct VEXKeychainStore {
    func string(for key: String, allowAuthenticationUI: Bool) -> String? { nil }
}
struct VEXDeviceIdentityStore {
    private let fileStore: AppSensitiveFileStore
    init(fileStore: AppSensitiveFileStore = AppSensitiveFileStore()) { self.fileStore = fileStore }
    func getOrCreateDeviceId() -> String {
        guard let id = fileStore.string(for: "vex.auth.device_id") else {
            fatalError("Profile identity fixtures must supply an isolated installation ID")
        }
        return id
    }
    func getOrCreateDeviceIdentity() throws -> VEXDeviceIdentity { throw VEXKeychainError.invalidValue }
}
struct VEXDeviceIdentity {
    static let keyType = "p256_jwk"
    var publicKeyJWK: String { "" }
    func signature(for payload: String) throws -> String { throw VEXKeychainError.invalidValue }
    static func signaturePayload(challenge: DeviceIdentityChallenge, installationId: String,
        identityPublicKey: String, wireGuardPublicKey: String) -> String { "" }
}
enum IPv4Resolver {
    static func resolve(_ host: String) -> String? { nil }
}
SWIFT
for name in VPNProfileCacheTests VPNProfileCacheIdentityTests VPNProfileServiceIdentityTests; do
    cp "$root_dir/macos-native/Tests/VEXNativeMacTests/$name.swift" "$test_dir/"
done
cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "VEXProfileIdentityHarness", platforms: [.macOS(.v15)], targets: [
    .target(name: "VEXNativeMac"),
    .testTarget(name: "VEXNativeMacTests", dependencies: ["VEXNativeMac"])
], swiftLanguageModes: [.v5])
SWIFT
swiftc -frontend -parse "$native_dir/Stores/VEXAppState.swift"
swiftc -frontend -parse "$native_dir/Services/VPNProfileService.swift"
swift test --package-path "$harness_dir"

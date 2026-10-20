#!/usr/bin/env bash
# Exercise the production API/profile/cache flow without AppKit or live secure
# stores. CryptoKit/keychain identity generation and DNS are isolated below;
# full macOS package CI still compiles and tests their production implementations.
# --api-contract-probe explicitly runs the shared API scenarios without XCTest.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-profile-identity.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
source_dir="$harness_dir/Sources/VEXNativeMac"
test_dir="$harness_dir/Tests/VEXNativeMacTests"
mkdir -p "$source_dir" "$test_dir"
native_dir="$root_dir/macos-native/Sources/VEXNativeMac"
swiftpm_args=()
if [[ "$(uname -s)" == Darwin && "$root_dir" == /Volumes/D/* ]]; then
    swift_cache=/Volumes/D/VEX-CI/cache/swift-client-patch-integration
    export CLANG_MODULE_CACHE_PATH=/Volumes/D/VEX-CI/cache/swift-modules-client-patches
    export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
    mkdir -p "$swift_cache/cache" "$swift_cache/config" "$swift_cache/security" "$CLANG_MODULE_CACHE_PATH"
    swiftpm_args=(--cache-path "$swift_cache/cache" --config-path "$swift_cache/config"
                  --security-path "$swift_cache/security" --scratch-path "$harness_dir/.build" --manifest-cache local)
fi
cp "$native_dir/Models/VEXModels.swift" "$source_dir/"
for name in VPNProfileCache VPNProfileCacheIdentity VPNAccountScope AppSensitiveFileStore NativeAwgBoolean VEXAPITransport VEXAPIConfiguration VEXAPIError; do
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
        let bytes = Array(UUID().uuidString.utf8.prefix(32))
        let privateKey = Data(bytes)
        return WireGuardKeyPair(privateKey: privateKey.base64EncodedString(),
            publicKey: privateKey.base64EncodedString(), keyEpoch: epoch)
    }
    private func publicKeyMatches(privateKey: Data, publicKey: Data) -> Bool {
        // Curve25519 math is covered by the complete native macOS XCTest lane.
        // Preserve the standard known pairs and the isolated generated fixtures.
        let standard = [
            "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=": "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=",
            "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=": "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=",
        ]
        return standard[privateKey.base64EncodedString()] == publicKey.base64EncodedString() || privateKey == publicKey
    }
}
SWIFT
awk '/^import CryptoKit/ { next } /    func getOrCreateDeviceIdentity\(/ { exit } { print }' "$native_dir/Services/VEXDeviceIdentityStore.swift" > "$source_dir/VEXDeviceIdentityStore.swift"
cat >> "$source_dir/VEXDeviceIdentityStore.swift" <<'SWIFT'
    func getOrCreateDeviceIdentity() throws -> VEXDeviceIdentity { VEXDeviceIdentity() }
}
SWIFT
cat > "$source_dir/IsolatedPlatformStores.swift" <<'SWIFT'
import Foundation
enum VEXKeychainError: Error { case invalidValue }
struct VEXKeychainStore: VEXDeviceIdentityKeychain {
    func string(for key: String, allowAuthenticationUI: Bool) -> String? { nil }
    func stringIfPresent(for key: String, allowAuthenticationUI: Bool) throws -> String? { nil }
    func setString(_ value: String, for key: String, requiresBiometricAuthentication: Bool) throws { }
}
struct VEXDeviceIdentity {
    static let keyType = "p256_jwk"
    var publicKeyJWK: String { "isolated-signing-key" }
    func signature(for payload: String) throws -> String { "isolated-signature" }
    static func signaturePayload(challenge: DeviceIdentityChallenge, installationId: String,
        identityPublicKey: String, wireGuardPublicKey: String) -> String { "" }
}
enum IPv4Resolver {
    static func resolve(_ host: String) -> String? { nil }
}
SWIFT
for name in VPNProfileCacheTests VPNProfileCacheIdentityTests VPNProfileServiceIdentityTests VPNAccountIdentityTests VEXAPIResponseContractTests; do
    cp "$root_dir/macos-native/Tests/VEXNativeMacTests/$name.swift" "$test_dir/"
done
if [[ "${1:-}" == --api-contract-probe ]]; then
    shift
    # Use the exact same scenarios in the explicit CLT executable and XCTest.
    cp "$root_dir/macos-native/Tests/VEXNativeMacTests/Support/APIContractScenarios.swift" "$source_dir/"
    cp "$root_dir/scripts/tests/vex_api_contract_probe.swift" "$source_dir/"
    cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "VEXAPIContractProbe", platforms: [.macOS(.v15)], targets: [
    .executableTarget(name: "VEXNativeMac")
], swiftLanguageModes: [.v5])
SWIFT
    swift run --package-path "$harness_dir" -j 2 ${swiftpm_args[@]+"${swiftpm_args[@]}"} -Xswiftc -DVEX_API_STANDALONE VEXNativeMac "$@"
    exit
fi
cp "$root_dir/macos-native/Tests/VEXNativeMacTests/Support/APIContractScenarios.swift" "$test_dir/"
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
swift test --package-path "$harness_dir" -j 2 ${swiftpm_args[@]+"${swiftpm_args[@]}"} "$@"

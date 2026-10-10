#!/usr/bin/env bash
# Compile the production Foundation transport and error model independently of
# AppKit/Sparkle. Full macOS app/device acceptance still uses the main package.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-api-transport.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
mkdir -p "$harness_dir/Sources/VEXAPITransportHarness" "$harness_dir/Tests/VEXAPITransportHarnessTests"
cp "$root_dir/macos-native/Sources/VEXNativeMac/Services/VEXAPITransport.swift" "$harness_dir/Sources/VEXAPITransportHarness/"
cp "$root_dir/macos-native/Tests/VEXNativeMacTests/VEXAPITransportTests.swift" "$harness_dir/Tests/VEXAPITransportHarnessTests/"
{
    printf 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
    awk '/^enum VEXAPIError:/ { copying = 1 } copying { print }' "$root_dir/macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift"
} > "$harness_dir/Sources/VEXAPITransportHarness/VEXAPIError.swift"

cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "VEXAPITransportHarness", platforms: [.macOS(.v15)], targets: [
    .target(name: "VEXAPITransportHarness"),
    .testTarget(name: "VEXAPITransportHarnessTests", dependencies: ["VEXAPITransportHarness"])
], swiftLanguageModes: [.v5])
SWIFT
swiftc -frontend -parse "$root_dir/macos-native/Sources/VEXNativeMac/Services/VEXAPIClient.swift"
swift test --package-path "$harness_dir" --filter VEXAPITransportTests

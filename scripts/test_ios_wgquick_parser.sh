#!/usr/bin/env bash
# Run the production parser with property-only WireGuardKit models. This checks
# parser sections and field preservation, not Network.framework or an iOS SDK.
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-ios-wgquick-parser.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
mkdir -p "$harness_dir/Sources/WireGuardKit" "$harness_dir/Sources/IosWgQuickParserHarness" "$harness_dir/Tests/IosWgQuickParserHarnessTests"
cp "$root_dir/modules/vex-vpn/ios/tunnel/WgQuickTunnelConfiguration.swift" "$harness_dir/Sources/IosWgQuickParserHarness/"
cp "$root_dir/tests/ios-wgquick-parser/WireGuardKitModels.swift" "$harness_dir/Sources/WireGuardKit/"
cp "$root_dir/tests/ios-wgquick-parser/IosWgQuickParserTests.swift" "$harness_dir/Tests/IosWgQuickParserHarnessTests/"
cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IosWgQuickParserHarness", platforms: [.macOS(.v15)], targets: [
  .target(name: "WireGuardKit"),
  .target(name: "IosWgQuickParserHarness", dependencies: ["WireGuardKit"]),
  .testTarget(name: "IosWgQuickParserHarnessTests", dependencies: ["IosWgQuickParserHarness", "WireGuardKit"])
], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$harness_dir" -j 2 --filter IosWgQuickParserTests

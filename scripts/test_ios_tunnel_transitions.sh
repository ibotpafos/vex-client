#!/usr/bin/env bash
# Exercise the production iOS transition controller without NetworkExtension,
# signing, device access, or VPN preference writes. This is not an iOS SDK build.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-ios-transitions.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
mkdir -p "$harness_dir/Sources/IosTunnelTransitionHarness" "$harness_dir/Tests/IosTunnelTransitionHarnessTests"
cp "$root_dir/modules/vex-vpn/ios/IosTunnelTransition.swift" "$harness_dir/Sources/IosTunnelTransitionHarness/"
cp "$root_dir/tests/ios-tunnel-transitions/IosTunnelTransitionTests.swift" "$harness_dir/Tests/IosTunnelTransitionHarnessTests/"
cat > "$harness_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IosTunnelTransitionHarness", platforms: [.macOS(.v15)], targets: [
  .target(name: "IosTunnelTransitionHarness"),
  .testTarget(name: "IosTunnelTransitionHarnessTests", dependencies: ["IosTunnelTransitionHarness"])
], swiftLanguageModes: [.v5])
SWIFT
swiftc -frontend -parse "$root_dir/modules/vex-vpn/ios/VexVpnModule.swift"
swift test --package-path "$harness_dir" --filter IosTunnelTransitionTests

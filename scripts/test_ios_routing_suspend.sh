#!/usr/bin/env bash
# Pure Foundation fixture: no preferences, NetworkExtension or physical sockets.
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-ios-routing-suspend.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  "$root_dir/modules/vex-vpn/ios/IosTunnelTransition.swift" \
  "$root_dir/tests/ios-routing-suspend/main.swift" -o "$fixture_dir/check"
"$fixture_dir/check"

#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-ios-runtime-test.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT
swiftc -swift-version 5 -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-${work_dir}/module-cache}" \
  "${root}/modules/vex-vpn/ios/IosTunnelRuntime.swift" \
  "${root}/tests/ios-tunnel-runtime.test.swift" -o "${work_dir}/runtime-test"
"${work_dir}/runtime-test"

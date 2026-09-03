#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/vex-ios-runtime-status.XXXXXX")"
trap 'rm -rf "${build_dir}"' EXIT

rg -Fq '"IosTunnelRuntimeStatus.swift"' "${root_dir}/modules/vex-vpn/ios/VexVpn.podspec"
rg -Fq '(config: String, antiLeakEnabled: Bool)' "${root_dir}/modules/vex-vpn/ios/VexVpnModule.swift"
rg -Fq '(releaseAntiLeak: Bool)' "${root_dir}/modules/vex-vpn/ios/VexVpnModule.swift"
rg -Fq 'try await waitForConnected(manager)' "${root_dir}/modules/vex-vpn/ios/VexVpnModule.swift"
rg -Fq 'tests/ios_tunnel_runtime_status_contract.sh' "${root_dir}/scripts/ios_preflight.sh"

swiftc \
  "${root_dir}/modules/vex-vpn/ios/IosTunnelRuntimeStatus.swift" \
  "${root_dir}/tests/ios_tunnel_runtime_status_contract.swift" \
  -o "${build_dir}/ios-tunnel-runtime-status-contract"

"${build_dir}/ios-tunnel-runtime-status-contract"

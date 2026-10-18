#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"
apple_repo_url="${AMNEZIAWG_APPLE_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-apple.git}"
apple_ref="4bafa5958a80c8be76bd89d1e02984c6307769d2"
go_version="v3.1.20260828"
reference_repo="${AMNEZIAWG_APPLE_REFERENCE_REPO:-/Users/ibotpafos/projects/VPN/external/amnezia/amneziawg-apple}"
apple_dir="${external_dir}/amneziawg-apple"

mkdir -p "${external_dir}"

if [[ ! -d "${apple_dir}/.git" ]]; then
  clone_args=(clone --recursive)
  if [[ -d "${reference_repo}/.git" ]]; then
    clone_args+=(--reference "${reference_repo}")
  fi
  git "${clone_args[@]}" "${apple_repo_url}" "${apple_dir}"
fi

git -C "${apple_dir}" fetch --depth 1 origin "${apple_ref}"
git -C "${apple_dir}" checkout --detach "${apple_ref}"
git -C "${apple_dir}" reset --hard "${apple_ref}"
git -C "${apple_dir}" submodule update --init --recursive --depth 1
git -C "${apple_dir}" apply "${root_dir}/patches/amnezia/amneziawg-apple-native-routing.patch"

bridge_dir="${apple_dir}/Sources/WireGuardKitGo"
# VEX uses AWG only. The unused Xray bridge selects a different gVisor ABI;
# compiling it into this library would also enlarge the packet extension.
mv "${bridge_dir}/api-xray.go" "${bridge_dir}/api-xray.go.upstream"
cat > "${bridge_dir}/go.mod" <<'EOF'
module golang.zx2c4.com/wireguard/apple

go 1.25.0

require github.com/amnezia-vpn/amneziawg-go/v3 v3.1.20260828
EOF
cp "${root_dir}/native-routing/bridges/apple/vex_routing_apple.go" "${bridge_dir}/"
(
  cd "${bridge_dir}"
  go mod edit -require="github.com/amnezia-vpn/amneziawg-go/v3@${go_version}"
  go mod edit -require=vex.dev/native-routing@v0.0.0
  go mod edit "-replace=vex.dev/native-routing=${root_dir}/native-routing"
  go mod tidy
  go mod download "github.com/amnezia-vpn/amneziawg-go/v3@${go_version}"
  go mod verify
)
"${root_dir}/scripts/verify_amneziawg_keepalive_upstream.sh" module "${bridge_dir}" "${go_version}"

echo "AMNEZIAWG_APPLE_DIR=${apple_dir}"

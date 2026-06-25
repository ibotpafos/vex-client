#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"
apple_repo_url="${AMNEZIAWG_APPLE_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-apple.git}"
apple_ref="${AMNEZIAWG_APPLE_REF:-0c4d98d1bd927bbba1c3b23c382c3f8881fd6631}"
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

git -C "${apple_dir}" fetch --depth 1 origin "${apple_ref}" || true
git -C "${apple_dir}" checkout --detach "${apple_ref}"
git -C "${apple_dir}" submodule update --init --recursive --depth 1

echo "AMNEZIAWG_APPLE_DIR=${apple_dir}"

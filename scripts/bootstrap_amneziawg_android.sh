#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"

android_repo_url="${AMNEZIAWG_ANDROID_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-android.git}"
go_repo_url="${AMNEZIAWG_GO_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-go.git}"
android_ref="${AMNEZIAWG_ANDROID_REF:-fb64e74ba5a0a54e9185b8776bcb8088afb772c9}"
go_ref="${AMNEZIAWG_GO_REF:-f4f4c999267437c3eb909e8d0e5278fb4596d9a7}"
clean_checkout="${AMNEZIAWG_CLEAN:-1}"

clone_or_reset() {
  local name="$1"
  local url="$2"
  local ref="$3"
  local dir="${external_dir}/${name}"

  mkdir -p "${external_dir}"
  if [[ ! -d "${dir}/.git" ]]; then
    git clone --filter=blob:none --no-checkout "${url}" "${dir}"
  fi

  git -C "${dir}" fetch --depth 1 origin "${ref}"
  git -C "${dir}" checkout --detach FETCH_HEAD
  git -C "${dir}" reset --hard FETCH_HEAD
  if [[ "${clean_checkout}" == "1" ]]; then
    git -C "${dir}" clean -fdx
  fi
}

clone_or_reset "amneziawg-go" "${go_repo_url}" "${go_ref}"
git -C "${external_dir}/amneziawg-go" apply "${root_dir}/patches/amnezia/amneziawg-go-fast-rekey.patch"

clone_or_reset "amneziawg-android" "${android_repo_url}" "${android_ref}"
git -C "${external_dir}/amneziawg-android" submodule update --init --recursive --depth 1
git -C "${external_dir}/amneziawg-android" apply "${root_dir}/patches/amnezia/amneziawg-android-macos-local-go.patch"

echo "AMNEZIAWG_TUNNEL_DIR=${external_dir}/amneziawg-android/tunnel"

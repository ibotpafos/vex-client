#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"

go_repo_url="${AMNEZIAWG_GO_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-go.git}"
tools_repo_url="${AMNEZIAWG_TOOLS_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-tools.git}"
go_ref="${AMNEZIAWG_GO_REF:-f4f4c999267437c3eb909e8d0e5278fb4596d9a7}"
tools_ref="${AMNEZIAWG_TOOLS_REF:-5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079}"
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

apply_patch_once() {
  local dir="$1"
  local patch="$2"

  if git -C "${dir}" apply --check "${patch}" >/dev/null 2>&1; then
    git -C "${dir}" apply "${patch}"
    return
  fi
  if git -C "${dir}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
    return
  fi

  echo "Cannot apply patch cleanly: ${patch}" >&2
  exit 1
}

clone_or_reset "amneziawg-go" "${go_repo_url}" "${go_ref}"
apply_patch_once "${external_dir}/amneziawg-go" "${root_dir}/patches/amnezia/amneziawg-go-fast-rekey.patch"

clone_or_reset "amneziawg-tools" "${tools_repo_url}" "${tools_ref}"

echo "AMNEZIAWG_MACOS_DIR=${external_dir}"

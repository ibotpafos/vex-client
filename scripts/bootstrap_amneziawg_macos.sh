#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"

go_repo_url="${AMNEZIAWG_GO_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-go.git}"
tools_repo_url="${AMNEZIAWG_TOOLS_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-tools.git}"
go_ref="${AMNEZIAWG_GO_REF:-08d68cdae27762c3e07f36bbb12d2bad32f81926}"
tools_ref="${AMNEZIAWG_TOOLS_REF:-9f70177d204d5be66c5b043518a57b7d62b3f9d1}"
clean_checkout="${AMNEZIAWG_CLEAN:-1}"

clone_or_reset() {
  local name="$1"
  local url="$2"
  local ref="$3"
  local dir="${external_dir}/${name}"

  mkdir -p "${external_dir}"
  if [[ -d "${dir}/.git" ]]; then
    local current_head
    current_head="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${current_head}" == "${ref}" ]]; then
      echo "${name} is already at ref ${ref}, skipping reset/fetch"
      return 1 # skipped
    fi
  fi

  if [[ ! -d "${dir}/.git" ]]; then
    git clone --filter=blob:none --no-checkout "${url}" "${dir}"
  fi

  git -C "${dir}" fetch --depth 1 origin "${ref}"
  git -C "${dir}" checkout --detach FETCH_HEAD
  git -C "${dir}" reset --hard FETCH_HEAD
  if [[ "${clean_checkout}" == "1" ]]; then
    git -C "${dir}" clean -fdx
  fi
  return 0 # did reset
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

clone_or_reset "amneziawg-go" "${go_repo_url}" "${go_ref}" || true
apply_patch_once "${external_dir}/amneziawg-go" "${root_dir}/patches/amnezia/amneziawg-go-fast-rekey.patch"

clone_or_reset "amneziawg-tools" "${tools_repo_url}" "${tools_ref}" || true

echo "AMNEZIAWG_MACOS_DIR=${external_dir}"

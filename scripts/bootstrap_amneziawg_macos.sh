#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"

go_repo_url="${AMNEZIAWG_GO_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-go.git}"
tools_repo_url="${AMNEZIAWG_TOOLS_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-tools.git}"
go_ref="b5928efb6ca19f0153958460c3d141f04abc5c2e"
tools_ref="ee0f0a9aa34ff0a0da4b3433b9512781cfe02843"
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

clone_or_reset "amneziawg-go" "${go_repo_url}" "${go_ref}" || true
"${root_dir}/scripts/verify_amneziawg_keepalive_upstream.sh" source "${external_dir}/amneziawg-go" "${go_ref}"

clone_or_reset "amneziawg-tools" "${tools_repo_url}" "${tools_ref}" || true

echo "AMNEZIAWG_MACOS_DIR=${external_dir}"

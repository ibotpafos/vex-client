#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_dir="${AMNEZIAWG_EXTERNAL_DIR:-"${root_dir}/external/amnezia"}"

android_repo_url="${AMNEZIAWG_ANDROID_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-android.git}"
go_repo_url="${AMNEZIAWG_GO_REPO_URL:-https://github.com/amnezia-vpn/amneziawg-go.git}"
android_ref="5c16489e2cd9ed3a0a7a27c7445bba5238132f86"
go_ref="b5928efb6ca19f0153958460c3d141f04abc5c2e"
clean_checkout="${AMNEZIAWG_CLEAN:-1}"

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

# Earlier VEX patches replaced the pre-v3 module name and did not select the
# engine actually imported by the pinned wrapper. Reverse that exact legacy
# patch first; refuse unrelated edits rather than resetting a reused checkout.
migrate_legacy_local_go_patch() {
  local dir="$1" patch="$2" legacy
  if git -C "${dir}" apply --check "${patch}" >/dev/null 2>&1 ||
     git -C "${dir}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
    return
  fi
  legacy="$(mktemp)"
  sed 's@replace github.com/amnezia-vpn/amneziawg-go/v3 =>@replace github.com/amnezia-vpn/amneziawg-go =>@' "${patch}" > "${legacy}"
  if git -C "${dir}" apply --reverse --check "${legacy}" >/dev/null 2>&1; then
    git -C "${dir}" apply --reverse "${legacy}"
  else
    rm -f "${legacy}"
    echo "Local Go patch differs from both supported forms" >&2
    exit 1
  fi
  rm -f "${legacy}"
}

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

if clone_or_reset "amneziawg-android" "${android_repo_url}" "${android_ref}"; then
  git -C "${external_dir}/amneziawg-android" submodule update --init --recursive --depth 1
fi
migrate_legacy_local_go_patch "${external_dir}/amneziawg-android" "${root_dir}/patches/amnezia/amneziawg-android-macos-local-go.patch"
apply_patch_once "${external_dir}/amneziawg-android" "${root_dir}/patches/amnezia/amneziawg-android-macos-local-go.patch"
apply_patch_once "${external_dir}/amneziawg-android" "${root_dir}/patches/amnezia/amneziawg-android-vpn-foreground-service.patch"

# Check the effective module graph, not only the text of a potentially unused replace.
(cd "${external_dir}/amneziawg-android/tunnel/tools/libwg-go" &&
  go list -m -json github.com/amnezia-vpn/amneziawg-go/v3) |
  python3 -c 'import json, pathlib, sys
module = json.load(sys.stdin)
expected = pathlib.Path(sys.argv[1]).resolve()
replacement = module.get("Replace", {})
if module.get("Path") != "github.com/amnezia-vpn/amneziawg-go/v3" or not replacement.get("Dir") or pathlib.Path(replacement["Dir"]).resolve() != expected:
    sys.exit("Pinned AWG Go v3 module did not resolve to the verified local checkout")
print("AMNEZIAWG_GO_V3_LOCAL_REPLACEMENT=verified")' "${external_dir}/amneziawg-go"

echo "AMNEZIAWG_TUNNEL_DIR=${external_dir}/amneziawg-android/tunnel"

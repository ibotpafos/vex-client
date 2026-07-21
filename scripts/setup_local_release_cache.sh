#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/local_release_env.sh" >/dev/null

MOVE_EXISTING="${VEX_LOCAL_CACHE_MOVE_EXISTING:-0}"

ensure_linked_dir() {
  local repo_path="$1"
  local cache_name="$2"
  local source_path="${ROOT}/${repo_path}"
  local cache_path="${VEX_LOCAL_RELEASE_CACHE_ROOT}/${cache_name}"

  mkdir -p "$(dirname "${cache_path}")"

  if [[ -L "${source_path}" ]]; then
    local current_target
    current_target="$(readlink "${source_path}")"
    if [[ "${current_target}" == "${cache_path}" ]]; then
      echo "cache link ok: ${repo_path} -> ${cache_path}"
      return 0
    fi
    echo "refusing to replace existing symlink: ${repo_path} -> ${current_target}" >&2
    exit 1
  fi

  if [[ -e "${source_path}" ]]; then
    if [[ ! -d "${source_path}" ]]; then
      echo "refusing to replace non-directory path: ${repo_path}" >&2
      exit 1
    fi

    if [[ -z "$(find "${source_path}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      rmdir "${source_path}"
    elif [[ "${MOVE_EXISTING}" == "1" ]]; then
      if [[ -e "${cache_path}" ]]; then
        echo "cache destination already exists; not merging automatically: ${cache_path}" >&2
        echo "remove it or choose another VEX_LOCAL_RELEASE_CACHE_ROOT" >&2
        exit 1
      fi
      mkdir -p "$(dirname "${cache_path}")"
      mv "${source_path}" "${cache_path}"
      echo "moved ${repo_path} to ${cache_path}"
    else
      echo "leaving existing local directory in place: ${repo_path}" >&2
      echo "set VEX_LOCAL_CACHE_MOVE_EXISTING=1 to move it to ${cache_path}" >&2
      return 0
    fi
  fi

  mkdir -p "${cache_path}"
  mkdir -p "$(dirname "${source_path}")"
  ln -s "${cache_path}" "${source_path}"
  echo "linked ${repo_path} -> ${cache_path}"
}

ensure_linked_dir "src-tauri/target" "src-tauri-target"
ensure_linked_dir "src-tauri/.vex-stamps" "src-tauri-stamps"
ensure_linked_dir "android/.gradle" "android-dot-gradle"
ensure_linked_dir "android/build" "android-build"
ensure_linked_dir "android/app/build" "android-app-build"
ensure_linked_dir "android/app/.cxx" "android-app-cxx"
ensure_linked_dir "external/amnezia" "external-amnezia"

echo "local release cache setup complete"

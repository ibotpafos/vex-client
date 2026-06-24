#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOBILE_DIR="${ROOT_DIR}"
LOCK_DIR="${ROOT_DIR}/src-tauri/target/.vex-local-build.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"

cd "${ROOT_DIR}"

export NODE_ENV="${NODE_ENV:-production}"
export VEX_BUILD_PROFILE="${VEX_BUILD_PROFILE:-local}"
export EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${EXPO_PUBLIC_VEX_RELEASE_CHANNEL:-local}"
export EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-local}"

release_build_lock() {
  rm -f "${LOCK_PID_FILE}"
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

acquire_build_lock() {
  mkdir -p "$(dirname "${LOCK_DIR}")"
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "$$" >"${LOCK_PID_FILE}"
    trap release_build_lock EXIT
    return
  fi

  local existing_pid=""
  if [[ -f "${LOCK_PID_FILE}" ]]; then
    existing_pid="$(cat "${LOCK_PID_FILE}")"
  fi

  if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
    echo "Another local macOS build is already running (pid ${existing_pid})." >&2
    exit 75
  fi

  echo "Removing stale local build lock." >&2
  rm -f "${LOCK_PID_FILE}"
  rmdir "${LOCK_DIR}" 2>/dev/null || {
    echo "Cannot acquire local build lock: ${LOCK_DIR}" >&2
    exit 75
  }
  mkdir "${LOCK_DIR}"
  echo "$$" >"${LOCK_PID_FILE}"
  trap release_build_lock EXIT
}

host_tauri_target() {
  case "$(uname -m)" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "universal-apple-darwin" ;;
  esac
}

json_config() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

targets = [target.strip() for target in sys.argv[1].split(",") if target.strip()]
config = {
    "bundle": {
        "createUpdaterArtifacts": False,
        "targets": targets,
        "resources": [
            "resources/amneziawg-go",
            "resources/awg",
            "resources/vex-helper",
            "resources/install-vex-vpn-helper.sh",
        ],
    }
}
if sys.argv[2] == "0":
    config["build"] = {"beforeBuildCommand": None}
else:
    config["build"] = {"beforeBuildCommand": "npm run build:web -- --clear"}
print(json.dumps(config))
PY
}

TAURI_TARGET="${TAURI_TARGET:-$(host_tauri_target)}"
TAURI_BUNDLE_TARGETS="${TAURI_BUNDLE_TARGETS:-app}"
BUILD_NATIVE_RESOURCES="${BUILD_NATIVE_RESOURCES:-1}"
BUILD_WEB="${BUILD_WEB:-1}"

echo "== Local macOS Tauri build =="
echo "Target: ${TAURI_TARGET}"
echo "Bundle targets: ${TAURI_BUNDLE_TARGETS}"
echo "Build web: ${BUILD_WEB}"

acquire_build_lock

cd "${MOBILE_DIR}"
if [[ "${BUILD_NATIVE_RESOURCES}" == "1" ]]; then
  HOST_ONLY=1 scripts/build_universal_resources.sh
  HELPER_TARGET=host npm run build:helper
else
  echo "Native resources: skipped (BUILD_NATIVE_RESOURCES=0)"
fi

if command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER=sccache
fi

TAURI_DEBUG="${TAURI_DEBUG:-0}"
tauri_config="$(json_config "${TAURI_BUNDLE_TARGETS}" "${BUILD_WEB}")"
build_args=()
if [[ "${TAURI_DEBUG}" == "1" ]]; then
  build_args+=(--debug)
  echo "Build mode: debug"
else
  echo "Build mode: release"
fi
npm run tauri:cli -- build --target "${TAURI_TARGET}" --config "${tauri_config}" ${build_args[@]+"${build_args[@]}"}

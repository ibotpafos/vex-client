#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

source "${ROOT}/scripts/local_release_env.sh"

PLATFORMS="${LOCAL_RELEASE_PLATFORMS:-auto}"
RUN_CHECKS="${RUN_LOCAL_RELEASE_CHECKS:-1}"
MOVE_EXISTING="${VEX_LOCAL_CACHE_MOVE_EXISTING:-1}"
export VEX_LOCAL_CACHE_MOVE_EXISTING="${MOVE_EXISTING}"

load_env_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${path}"
    set +a
  fi
}

platform_selected() {
  local wanted="$1"
  if [[ "${PLATFORMS}" == "auto" || "${PLATFORMS}" == "all" ]]; then
    return 0
  fi

  local item
  IFS=',' read -ra items <<<"${PLATFORMS}"
  for item in "${items[@]}"; do
    if [[ "${item}" == "${wanted}" ]]; then
      return 0
    fi
  done
  return 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "${name} is required" >&2
    exit 2
  fi
}

require_private_key() {
  if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" && -z "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]]; then
    echo "TAURI_SIGNING_PRIVATE_KEY or TAURI_SIGNING_PRIVATE_KEY_PATH is required" >&2
    exit 2
  fi
  if [[ -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" && ! -f "${TAURI_SIGNING_PRIVATE_KEY_PATH}" ]]; then
    echo "TAURI_SIGNING_PRIVATE_KEY_PATH does not exist: ${TAURI_SIGNING_PRIVATE_KEY_PATH}" >&2
    exit 2
  fi
}

load_private_key_from_path() {
  if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" && -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]]; then
    TAURI_SIGNING_PRIVATE_KEY="$(cat "${TAURI_SIGNING_PRIVATE_KEY_PATH}")"
    export TAURI_SIGNING_PRIVATE_KEY
  fi
}

run_step() {
  echo
  echo "== $* =="
  "$@"
}

load_env_file "${ROOT}/.env.local-release"
load_env_file "${ROOT}/.env.tauri-updater.local"
load_env_file "${ROOT}/.env.signing.local"

require_command node
require_command npm
require_command cargo
require_command rustc

bash "${ROOT}/scripts/setup_local_release_cache.sh"

if [[ "${RUN_CHECKS}" == "1" ]]; then
  run_step npm ci --prefer-offline --no-audit --fund=false
  run_step npm run typecheck
  run_step npm run test:unit
fi

host_os="$(uname -s)"

if platform_selected macos; then
  if [[ "${host_os}" == "Darwin" ]]; then
    require_private_key
    require_env TAURI_SIGNING_PRIVATE_KEY_PASSWORD
    require_env TAURI_SIGNING_PUBLIC_KEY
    load_private_key_from_path
    require_command go
    require_command codesign
    run_step rustup target add aarch64-apple-darwin x86_64-apple-darwin
    run_step cargo check --manifest-path src-tauri/Cargo.toml
    run_step npm run macos:release
  elif [[ "${PLATFORMS}" != "auto" ]]; then
    echo "macOS release requires macOS host" >&2
    exit 2
  else
    echo "skip macos: requires macOS host"
  fi
fi

if platform_selected android; then
  require_command java
  require_command keytool
  if [[ ! -f android/app/debug.keystore ]]; then
    keytool -genkeypair -v \
      -storetype JKS \
      -keystore android/app/debug.keystore \
      -storepass android \
      -alias androiddebugkey \
      -keypass android \
      -keyalg RSA \
      -keysize 2048 \
      -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US"
  fi
  export ANDROID_RELEASE_VARIANT="${ANDROID_RELEASE_VARIANT:-local}"
  export ANDROID_GRADLE_ARGS="${ANDROID_GRADLE_ARGS:--x lintVitalRelease -x lintVitalAnalyzeRelease -x lintVitalReportRelease}"
  export ANDROID_RELEASE_ABIS="${ANDROID_RELEASE_ABIS:-arm64-v8a}"
  run_step npm run android:release
fi

if platform_selected linux; then
  if [[ "${host_os}" == "Linux" ]]; then
    require_command sha256sum
    require_command dpkg-deb
    require_command rustup
    run_step rustup target add "${LINUX_TARGET:-x86_64-unknown-linux-gnu}"
    run_step cargo check --manifest-path src-tauri/Cargo.toml --target "${LINUX_TARGET:-x86_64-unknown-linux-gnu}"
    run_step npm run linux:release
  elif [[ "${PLATFORMS}" != "auto" ]]; then
    echo "linux release requires Linux host or a Linux VM/container with Tauri system dependencies" >&2
    exit 2
  else
    echo "skip linux: requires Linux host"
  fi
fi

if platform_selected windows; then
  if command -v pwsh >/dev/null 2>&1; then
    run_step rustup target add "${WINDOWS_TARGET:-x86_64-pc-windows-msvc}"
    run_step cargo check --manifest-path src-tauri/Cargo.toml --target "${WINDOWS_TARGET:-x86_64-pc-windows-msvc}"
    run_step npm run windows:release
  elif [[ "${PLATFORMS}" != "auto" ]]; then
    echo "windows release requires PowerShell plus the Windows Rust/MSVC toolchain on a Windows host" >&2
    exit 2
  else
    echo "skip windows: requires Windows host"
  fi
fi

echo
echo "local release build complete"
find dist -maxdepth 2 -type f -print 2>/dev/null | sort || true

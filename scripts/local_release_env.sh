#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
DEFAULT_CACHE_ROOT="/Volumes/D/Downloads/VEX/local-release-cache/vex-client"
VEX_LOCAL_RELEASE_CACHE_ROOT="${VEX_LOCAL_RELEASE_CACHE_ROOT:-${DEFAULT_CACHE_ROOT}}"

if [[ ! -d "$(dirname "${VEX_LOCAL_RELEASE_CACHE_ROOT}")" ]]; then
  mkdir -p "$(dirname "${VEX_LOCAL_RELEASE_CACHE_ROOT}")"
fi
mkdir -p \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/npm" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/cargo-home" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/gradle-user-home" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-build" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-mod" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/expo-home" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/metro-cache" \
  "${VEX_LOCAL_RELEASE_CACHE_ROOT}/tmp"

export VEX_LOCAL_RELEASE_CACHE_ROOT

if [[ "${VEX_LOCAL_RELEASE_CACHE_STRICT:-1}" == "1" ]]; then
  export npm_config_cache="${VEX_LOCAL_RELEASE_CACHE_ROOT}/npm"
  export CARGO_HOME="${VEX_LOCAL_RELEASE_CACHE_ROOT}/cargo-home"
  export GRADLE_USER_HOME="${VEX_LOCAL_RELEASE_CACHE_ROOT}/gradle-user-home"
  export GOCACHE="${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-build"
  export GOMODCACHE="${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-mod"
  export EXPO_HOME="${VEX_LOCAL_RELEASE_CACHE_ROOT}/expo-home"
  export METRO_CACHE_DIR="${VEX_LOCAL_RELEASE_CACHE_ROOT}/metro-cache"
  export TMPDIR="${VEX_LOCAL_RELEASE_CACHE_ROOT}/tmp/"
else
  export npm_config_cache="${npm_config_cache:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/npm}"
  export CARGO_HOME="${CARGO_HOME:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/cargo-home}"
  export GRADLE_USER_HOME="${GRADLE_USER_HOME:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/gradle-user-home}"
  export GOCACHE="${GOCACHE:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-build}"
  export GOMODCACHE="${GOMODCACHE:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/go-mod}"
  export EXPO_HOME="${EXPO_HOME:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/expo-home}"
  export METRO_CACHE_DIR="${METRO_CACHE_DIR:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/metro-cache}"
  export TMPDIR="${TMPDIR:-${VEX_LOCAL_RELEASE_CACHE_ROOT}/tmp/}"
fi

export ANDROID_HOME="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME}}"

case ":${PATH}:" in
  *":${HOME}/.cargo/bin:"*) ;;
  *) export PATH="${HOME}/.cargo/bin:${PATH}" ;;
esac

printf 'VEX local release cache: %s\n' "${VEX_LOCAL_RELEASE_CACHE_ROOT}"

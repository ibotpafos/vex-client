#!/usr/bin/env bash
set -euo pipefail

vex_android_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${vex_android_root}/scripts/local_release_cache_bootstrap.sh"

android_sdk_is_usable() {
  local candidate="${1:-}"
  [[ -n "${candidate}" ]] \
    && [[ -d "${candidate}/platforms/android-36" ]] \
    && [[ -x "${candidate}/build-tools/36.0.0/aapt" ]] \
    && [[ -x "${candidate}/platform-tools/adb" ]] \
    && [[ -d "${candidate}/ndk/27.1.12297006" ]]
}

java_home_is_usable() {
  local candidate="${1:-}"
  local specification_version=""
  if [[ -z "${candidate}" ]] || [[ ! -x "${candidate}/bin/java" ]] || [[ ! -x "${candidate}/bin/keytool" ]]; then
    return 1
  fi
  specification_version="$("${candidate}/bin/java" -XshowSettings:properties -version 2>&1 \
    | sed -n 's/^[[:space:]]*java\.specification\.version = //p' \
    | head -1)"
  [[ "${specification_version%%.*}" =~ ^[0-9]+$ ]] \
    && (( ${specification_version%%.*} >= 17 ))
}

resolve_java_home() {
  local candidate=""
  local -a candidates=(
    "${VEX_JAVA_HOME:-}"
    "${JAVA_HOME:-}"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  )

  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    candidates+=("${candidate}")
  fi
  if command -v brew >/dev/null 2>&1; then
    candidate="$(brew --prefix openjdk@17 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
      candidates+=("${candidate}/libexec/openjdk.jdk/Contents/Home")
    fi
  fi

  for candidate in "${candidates[@]}"; do
    if java_home_is_usable "${candidate}"; then
      export JAVA_HOME="${candidate}"
      return 0
    fi
  done

  echo "Android build requires JDK 17. Set VEX_JAVA_HOME once or install openjdk@17." >&2
  return 1
}

resolve_android_sdk() {
  local cache_file="${VEX_LOCAL_RELEASE_CACHE_ROOT}/android-sdk-path"
  local cached_sdk=""
  local properties_sdk=""
  local command_path=""
  local candidate=""

  if [[ -f "${cache_file}" ]]; then
    IFS= read -r cached_sdk < "${cache_file}" || true
  fi
  if [[ -f "${vex_android_root}/android/local.properties" ]]; then
    properties_sdk="$(sed -n 's/^sdk\.dir=//p' "${vex_android_root}/android/local.properties" | tail -1)"
    properties_sdk="${properties_sdk//\\:/:}"
    properties_sdk="${properties_sdk//\\ / }"
  fi

  local -a candidates=(
    "${VEX_ANDROID_SDK_ROOT:-}"
    "${ANDROID_HOME:-}"
    "${ANDROID_SDK_ROOT:-}"
    "${properties_sdk}"
    "${cached_sdk}"
    "${HOME}/Library/Android/sdk"
  )
  if command -v adb >/dev/null 2>&1; then
    command_path="$(command -v adb)"
    candidates+=("$(cd "$(dirname "${command_path}")/.." && pwd)")
  fi

  for candidate in "${candidates[@]}"; do
    if android_sdk_is_usable "${candidate}"; then
      export ANDROID_HOME="${candidate}"
      export ANDROID_SDK_ROOT="${candidate}"
      printf '%s\n' "${candidate}" > "${cache_file}"
      return 0
    fi
  done

  echo "Android SDK was not found. Set VEX_ANDROID_SDK_ROOT once; the resolved path will be cached." >&2
  return 1
}

prepare_debug_keystore() {
  local debug_keystore="${vex_android_root}/android/app/debug.keystore"
  local shared_keystore="${VEX_LOCAL_RELEASE_CACHE_ROOT}/android-debug.keystore"
  local seed_keystore="${VEX_ANDROID_DEBUG_KEYSTORE_SOURCE:-}"

  if [[ -n "${seed_keystore}" ]]; then
    if [[ ! -f "${seed_keystore}" ]]; then
      echo "VEX_ANDROID_DEBUG_KEYSTORE_SOURCE does not exist: ${seed_keystore}" >&2
      return 1
    fi
    cp "${seed_keystore}" "${shared_keystore}"
  fi

  if [[ ! -f "${shared_keystore}" ]]; then
    if [[ -f "${debug_keystore}" ]]; then
      cp "${debug_keystore}" "${shared_keystore}"
    else
      "${JAVA_HOME}/bin/keytool" -genkeypair -v \
        -storetype JKS \
        -keystore "${shared_keystore}" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US"
    fi
  fi

  if [[ ! -f "${debug_keystore}" ]] || ! cmp -s "${shared_keystore}" "${debug_keystore}"; then
    cp "${shared_keystore}" "${debug_keystore}"
  fi
}

resolve_java_home
resolve_android_sdk
"${vex_android_root}/scripts/bootstrap_amneziawg_android.sh"

export AMNEZIAWG_TUNNEL_DIR="${AMNEZIAWG_TUNNEL_DIR:-"${vex_android_root}/external/amnezia/amneziawg-android/tunnel"}"
prepare_debug_keystore

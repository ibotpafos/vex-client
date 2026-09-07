#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${root_dir}/scripts/android_build_prepare.sh"

if [[ "${1:-}" == "--prepare-only" ]]; then
  printf 'Android build environment ready: JDK=%s SDK=%s\n' \
    "$("${JAVA_HOME}/bin/java" -version 2>&1 | head -1)" \
    "${ANDROID_HOME}"
  exit 0
fi

export VEX_BUILD_PROFILE="${VEX_BUILD_PROFILE:-development}"
export EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-development}"
export VEX_DEBUG_APPLICATION_ID_SUFFIX="${VEX_DEBUG_APPLICATION_ID_SUFFIX:-.debug}"
export VEX_RUNTIME_VERSION="${VEX_RUNTIME_VERSION:-$(node -p "require('${root_dir}/app.json').expo.version")}"
export NODE_ENV="${NODE_ENV:-development}"

cd "${root_dir}/android"
./gradlew :app:assembleDebug \
  -PreactNativeArchitectures="${REACT_NATIVE_ARCHITECTURES:-arm64-v8a}" \
  -PVEX_ANDROID_FAST_ABI="${VEX_ANDROID_FAST_ABI:-arm64-v8a}" \
  "$@"

expected_application_id="$(node -p "require('../app.json').expo.android.package")${VEX_DEBUG_APPLICATION_ID_SUFFIX}"
expected_version_code="$(node -p "require('../app.json').expo.android.versionCode")"
expected_version_name="$(node -p "require('../app.json').expo.version + '.debug'")"
"${root_dir}/scripts/verify_android_apk.sh" \
  "${root_dir}/android/app/build/outputs/apk/debug/app-debug.apk" \
  "${expected_application_id}" \
  "${expected_version_code}" \
  "${expected_version_name}" \
  "${VEX_ANDROID_FAST_ABI:-arm64-v8a}" \
  optional

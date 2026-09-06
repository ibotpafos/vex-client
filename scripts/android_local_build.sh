#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${root_dir}/scripts/android_build_prepare.sh"

export NODE_ENV="${NODE_ENV:-production}"
export VEX_BUILD_PROFILE="${VEX_BUILD_PROFILE:-local}"
export EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${EXPO_PUBLIC_VEX_RELEASE_CHANNEL:-local}"
export EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-local}"
# Dev builds are the acceptance surface for smart routing and anti-leak. The
# application reads the EXPO_PUBLIC name at bundle time; the older VEX_ alias
# silently left both switches forced off and made the device matrix invalid.
export EXPO_PUBLIC_VEX_ANDROID_EXPERIMENTAL_ROUTING="${EXPO_PUBLIC_VEX_ANDROID_EXPERIMENTAL_ROUTING:-1}"
# Local device builds must never replace or masquerade as a production VEX
# package. Keep the stable VEX Dev identity even when Gradle is invoked through
# this wrapper without any caller-provided properties. The Android applicationId
# must match app.json (and the literal in android/app/build.gradle); the iOS
# bundle identifier com.vexguard.app must never leak in here, or the final APK
# verification fails against a correct artifact.
export VEX_ANDROID_APPLICATION_ID="${VEX_ANDROID_APPLICATION_ID:-$(node -p "require('${root_dir}/app.json').expo.android.package")}"
export VEX_DEBUG_APPLICATION_ID_SUFFIX="${VEX_DEBUG_APPLICATION_ID_SUFFIX:-.dev}"

cd "${root_dir}/android"
output_apk="${root_dir}/android/app/build/outputs/apk/local/app-local.apk"
rm -f "${output_apk}"
if [[ "${VEX_ANDROID_LOCAL_OPTIMIZE:-0}" == "1" ]]; then
  local_optimization_args=(
    -Pandroid.enableMinifyInLocalBuilds=true
    -Pandroid.enableShrinkResourcesInLocalBuilds=true
  )
else
  local_optimization_args=(
    -Pandroid.enableMinifyInLocalBuilds=false
    -Pandroid.enableShrinkResourcesInLocalBuilds=false
  )
fi
./gradlew :app:assembleLocal \
  -PreactNativeArchitectures="${REACT_NATIVE_ARCHITECTURES:-arm64-v8a}" \
  -PVEX_ANDROID_FAST_ABI="${VEX_ANDROID_FAST_ABI:-arm64-v8a}" \
  "${local_optimization_args[@]}" \
  "$@"

expected_version_code="$(node -p "require('../app.json').expo.android.versionCode")"
expected_version_name="$(node -p "require('../app.json').expo.version + '.dev'")"
"${root_dir}/scripts/verify_android_apk.sh" \
  "${output_apk}" \
  "${VEX_ANDROID_APPLICATION_ID}${VEX_DEBUG_APPLICATION_ID_SUFFIX}" \
  "${expected_version_code}" \
  "${expected_version_name}" \
  "${VEX_ANDROID_FAST_ABI:-arm64-v8a}"

#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${root_dir}/scripts/bootstrap_amneziawg_android.sh"

export AMNEZIAWG_TUNNEL_DIR="${AMNEZIAWG_TUNNEL_DIR:-"${root_dir}/external/amnezia/amneziawg-android/tunnel"}"
export ANDROID_HOME="${ANDROID_HOME:-"${HOME}/Library/Android/sdk"}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-"${ANDROID_HOME}"}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export NODE_ENV="${NODE_ENV:-production}"
export VEX_BUILD_PROFILE="${VEX_BUILD_PROFILE:-local}"
export EXPO_PUBLIC_VEX_RELEASE_CHANNEL="${EXPO_PUBLIC_VEX_RELEASE_CHANNEL:-local}"
export EXPO_PUBLIC_VEX_UPDATE_CHANNEL="${EXPO_PUBLIC_VEX_UPDATE_CHANNEL:-local}"

cd "${root_dir}/android"
./gradlew :app:assembleLocal \
  -PreactNativeArchitectures="${REACT_NATIVE_ARCHITECTURES:-arm64-v8a}" \
  -PVEX_ANDROID_FAST_ABI="${VEX_ANDROID_FAST_ABI:-arm64-v8a}" \
  "$@"

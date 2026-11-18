#!/usr/bin/env bash
# Use the official SDK manager and one package manifest for CI and releases.
set -euo pipefail
vex_sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$vex_sdk_root" ]] || { echo "ANDROID_HOME or ANDROID_SDK_ROOT is required" >&2; exit 1; }
vex_sdkmanager="$vex_sdk_root/cmdline-tools/latest/bin/sdkmanager"
[[ -x "$vex_sdkmanager" ]] || { echo "Android SDK manager is missing from the configured SDK" >&2; exit 1; }
vex_sdk_packages="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android_sdk_packages.txt"
vex_cmake_version="$(sed -n 's/^cmake;//p' "$vex_sdk_packages")"
[[ "$vex_cmake_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "One pinned CMake package is required" >&2; exit 1; }
"$vex_sdkmanager" "--package_file=$vex_sdk_packages"
# Gradle's late SDK auto-install failed while unpacking a CMake archive. Fail
# during tool preparation if the requested compiler is still unavailable.
vex_cmake_binary="$vex_sdk_root/cmake/$vex_cmake_version/bin/cmake"
[[ -x "$vex_cmake_binary" ]] || { echo "Pinned CMake was not installed by the SDK manager" >&2; exit 1; }
"$vex_cmake_binary" --version

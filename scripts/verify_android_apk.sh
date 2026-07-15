#!/usr/bin/env bash
set -euo pipefail

apk_path="${1:?APK path is required}"
expected_package="${2:?expected package is required}"
expected_version_code="${3:?expected version code is required}"
expected_version_name="${4:?expected version name is required}"

if [[ ! -f "${apk_path}" ]]; then
  echo "APK is missing: ${apk_path}" >&2
  exit 1
fi

aapt_bin="${AAPT_BIN:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}/build-tools/36.0.0/aapt}"
if [[ ! -x "${aapt_bin}" ]]; then
  echo "aapt is required to verify the APK: ${aapt_bin}" >&2
  exit 2
fi

badging="$("${aapt_bin}" dump badging "${apk_path}")"
package_line="$(printf '%s\n' "${badging}" | sed -n 's/^package: //p' | head -n 1)"
actual_package="$(printf '%s\n' "${package_line}" | sed -n "s/.*name='\([^']*\)'.*/\1/p")"
actual_version_code="$(printf '%s\n' "${package_line}" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
actual_version_name="$(printf '%s\n' "${package_line}" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"

if [[ "${actual_package}" != "${expected_package}" || \
      "${actual_version_code}" != "${expected_version_code}" || \
      "${actual_version_name}" != "${expected_version_name}" ]]; then
  printf 'stale or incorrect APK: expected %s %s (%s), got %s %s (%s)\n' \
    "${expected_package}" "${expected_version_name}" "${expected_version_code}" \
    "${actual_package:-unknown}" "${actual_version_name:-unknown}" "${actual_version_code:-unknown}" >&2
  exit 1
fi

printf 'Verified APK: %s %s (%s)\n' \
  "${actual_package}" "${actual_version_name}" "${actual_version_code}"

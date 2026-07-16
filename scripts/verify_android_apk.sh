#!/usr/bin/env bash
set -euo pipefail

apk_path="${1:?APK path is required}"
expected_package="${2:?expected package is required}"
expected_version_code="${3:?expected version code is required}"
expected_version_name="${4:?expected version name is required}"
expected_abis="${5:-}"

if [[ ! -f "${apk_path}" ]]; then
  echo "APK is missing: ${apk_path}" >&2
  exit 1
fi

aapt_bin="${AAPT_BIN:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}/build-tools/36.0.0/aapt}"
if [[ ! -x "${aapt_bin}" ]]; then
  echo "aapt is required to verify the APK: ${aapt_bin}" >&2
  exit 2
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

hash_before="$(sha256_file "${apk_path}")"
badging="$("${aapt_bin}" dump badging "${apk_path}")"
package_line="$(printf '%s\n' "${badging}" | sed -n 's/^package: //p' | head -n 1)"
actual_package="$(printf '%s\n' "${package_line}" | sed -n "s/^name='\([^']*\)'.*/\1/p")"
actual_version_code="$(printf '%s\n' "${package_line}" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
actual_version_name="$(printf '%s\n' "${package_line}" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
bundle_size="$(unzip -l "${apk_path}" assets/index.android.bundle | awk '$NF == "assets/index.android.bundle" { print $1; exit }')"
actual_abis="$(unzip -Z1 "${apk_path}" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u)"

if [[ ! "${bundle_size:-}" =~ ^[0-9]+$ || "${bundle_size}" -lt 100000 ]]; then
  echo "APK does not contain a complete assets/index.android.bundle: ${apk_path}" >&2
  exit 1
fi

hash_after="$(sha256_file "${apk_path}")"
if [[ "${hash_before}" != "${hash_after}" ]]; then
  echo "APK changed while it was being verified; refusing a racing build artifact: ${apk_path}" >&2
  exit 1
fi

if [[ "${actual_package}" != "${expected_package}" || \
      "${actual_version_code}" != "${expected_version_code}" || \
      "${actual_version_name}" != "${expected_version_name}" ]]; then
  printf 'stale or incorrect APK: expected %s %s (%s), got %s %s (%s)\n' \
    "${expected_package}" "${expected_version_name}" "${expected_version_code}" \
    "${actual_package:-unknown}" "${actual_version_name:-unknown}" "${actual_version_code:-unknown}" >&2
  exit 1
fi

if [[ -n "${expected_abis}" ]]; then
  IFS=',' read -r -a required_abis <<<"${expected_abis}"
  for abi in "${required_abis[@]}"; do
    abi="$(printf '%s' "${abi}" | xargs)"
    [[ -n "${abi}" ]] || continue
    if ! printf '%s\n' "${actual_abis}" | grep -Fxq "${abi}"; then
      printf 'APK is missing required ABI %s; packaged ABIs: %s\n' \
        "${abi}" "$(printf '%s' "${actual_abis}" | tr '\n' ',' | sed 's/,$//')" >&2
      exit 1
    fi
  done
fi

printf 'Verified APK: %s %s (%s), ABIs %s, JS bundle %s bytes, sha256 %s\n' \
  "${actual_package}" "${actual_version_name}" "${actual_version_code}" \
  "$(printf '%s' "${actual_abis}" | tr '\n' ',' | sed 's/,$//')" \
  "${bundle_size}" "${hash_after}"

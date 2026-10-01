#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/macos-native"
RESOURCE_DIR="${PACKAGE_DIR}/HelperResources"
SCRATCH_ROOT="${PACKAGE_DIR}/.build-helper"
PRODUCT="VEXPrivilegedHelper"
OUTPUT="${RESOURCE_DIR}/vex-helper"
# An explicitly supplied identity (including ad-hoc "-") is an operator choice.
# Auto-provisioning/discovery may inspect and alter the user keychain, so only
# perform it when VEX_CODESIGN_IDENTITY was genuinely unset.
CODESIGN_IDENTITY_EXPLICIT=0
if [[ -n "${VEX_CODESIGN_IDENTITY+x}" ]]; then
  CODESIGN_IDENTITY="${VEX_CODESIGN_IDENTITY}"
  CODESIGN_IDENTITY_EXPLICIT=1
else
  CODESIGN_IDENTITY="-"
fi
CODESIGN_KEYCHAIN="${VEX_CODESIGN_KEYCHAIN:-}"
CODESIGN_TIMESTAMP="${VEX_CODESIGN_TIMESTAMP:-automatic}"
LOCAL_SIGNING_IDENTITY="VEX Self-Signed Application"
LOCAL_SIGNING_DIR="${VEX_LOCAL_SIGNING_DIR:-${HOME}/Library/Application Support/VEX Release/identities/macos-self-signed-v4}"
LOCAL_SIGNING_KEYCHAIN="${LOCAL_SIGNING_DIR}/VEX-Release-Build.keychain-db"
SIGNING_SEARCH_LIST_CHANGED=0
ORIGINAL_SIGNING_KEYCHAINS=()

restore_signing_search_list() {
  if [[ "${SIGNING_SEARCH_LIST_CHANGED}" == "1" ]]; then
    /usr/bin/security list-keychains -d user -s "${ORIGINAL_SIGNING_KEYCHAINS[@]}"
    SIGNING_SEARCH_LIST_CHANGED=0
  fi
}

activate_local_signing_keychain() {
  local line keychain
  while IFS= read -r line; do
    keychain="${line#*\"}"
    keychain="${keychain%\"*}"
    [[ -z "${keychain}" ]] || ORIGINAL_SIGNING_KEYCHAINS+=("${keychain}")
  done < <(/usr/bin/security list-keychains -d user)
  for keychain in "${ORIGINAL_SIGNING_KEYCHAINS[@]}"; do
    [[ "${keychain}" != "${LOCAL_SIGNING_KEYCHAIN}" ]] || return 0
  done
  /usr/bin/security list-keychains -d user -s \
    "${ORIGINAL_SIGNING_KEYCHAINS[@]}" "${LOCAL_SIGNING_KEYCHAIN}"
  SIGNING_SEARCH_LIST_CHANGED=1
}

if [[ "${CODESIGN_IDENTITY_EXPLICIT}" == "0" && "${CODESIGN_IDENTITY}" == "-" ]]; then
  if [[ -f "${LOCAL_SIGNING_DIR}/application.key.pem" \
        && -f "${LOCAL_SIGNING_DIR}/application.cert.pem" ]]; then
    /usr/bin/swift "${ROOT_DIR}/scripts/prepare_vex_local_signing_identity.swift" \
      "${LOCAL_SIGNING_DIR}" >&2
    if /usr/bin/security find-identity -v -p codesigning "${LOCAL_SIGNING_KEYCHAIN}" \
        | /usr/bin/grep -q "${LOCAL_SIGNING_IDENTITY}"; then
      CODESIGN_IDENTITY="${LOCAL_SIGNING_IDENTITY}"
      CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-${LOCAL_SIGNING_KEYCHAIN}}"
      CODESIGN_TIMESTAMP="none"
      activate_local_signing_keychain
    fi
  fi
fi

if [[ "${CODESIGN_IDENTITY_EXPLICIT}" == "0" && "${CODESIGN_IDENTITY}" == "-" ]]; then
  detected_identity="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk '/Apple Development:/{print $2; exit}' \
      | /usr/bin/head -n 1
  )"
  [[ -z "${detected_identity}" ]] || CODESIGN_IDENTITY="${detected_identity}"
fi

build_arch() {
  local arch="$1"
  local triple="${arch}-apple-macosx15.0"
  local scratch="${SCRATCH_ROOT}/${arch}"
  local build_args=(--package-path "${PACKAGE_DIR}" --scratch-path "${scratch}"
    --configuration "${VEX_MACOS_CONFIGURATION:-release}" --product "${PRODUCT}" --triple "${triple}")
  # errexit is disabled inside command substitution on macOS Bash. Explicitly
  # propagate failures, so an old executable can never masquerade as this build.
  /usr/bin/swift build "${build_args[@]}" >&2 || return 1
  local bin_dir
  bin_dir="$(/usr/bin/swift build "${build_args[@]}" --show-bin-path)" || return 1
  [[ -x "${bin_dir}/${PRODUCT}" ]] || return 1
  printf '%s\n' "${bin_dir}/${PRODUCT}"
}

mkdir -p "${RESOURCE_DIR}" "${SCRATCH_ROOT}"

arm_binary="$(build_arch arm64)"
x86_binary="$(build_arch x86_64)"
if [[ ! -x "${arm_binary}" || ! -x "${x86_binary}" ]]; then
  echo "Swift helper build did not produce both architecture binaries." >&2
  exit 1
fi

temporary_output="$(mktemp "${RESOURCE_DIR}/.vex-helper.XXXXXX")"
cleanup() {
  rm -f "${temporary_output}"
  restore_signing_search_list
}
trap cleanup EXIT

/usr/bin/lipo -create "${arm_binary}" "${x86_binary}" -output "${temporary_output}"
/bin/chmod 0755 "${temporary_output}"

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  /usr/bin/codesign --force --sign - "${temporary_output}"
else
  signing_args=(--force --options runtime --sign "${CODESIGN_IDENTITY}")
  [[ -z "${CODESIGN_KEYCHAIN}" ]] || signing_args+=(--keychain "${CODESIGN_KEYCHAIN}")
  if [[ "${CODESIGN_TIMESTAMP}" == "none" ]]; then
    signing_args+=(--timestamp=none)
  else
    signing_args+=(--timestamp)
  fi
  /usr/bin/codesign "${signing_args[@]}" "${temporary_output}"
fi
/usr/bin/codesign --verify --strict --verbose=2 "${temporary_output}"

/bin/mv -f "${temporary_output}" "${OUTPUT}"
trap - EXIT
restore_signing_search_list

/usr/bin/file "${OUTPUT}"
/usr/bin/shasum -a 256 "${OUTPUT}"

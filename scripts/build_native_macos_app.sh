#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/macos-native"
BUILD_DIR="${PACKAGE_DIR}/build"
APP_NAME="VEXNativeMac"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ICON_SOURCE="${ROOT_DIR}/assets/vex-app-icon-source.png"
ICONSET_DIR="${BUILD_DIR}/VEXNative.iconset"
ICNS_PATH="${APP_DIR}/Contents/Resources/VEXNative.icns"
APP_VERSION="${VEX_NATIVE_VERSION:-0.1.0}"
APP_BUILD="${VEX_NATIVE_BUILD:-1}"
SPARKLE_FEED_URL="${VEX_SPARKLE_FEED_URL:-https://vexguard.app/downloads/native-macos/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${VEX_SPARKLE_PUBLIC_ED_KEY:-cwILAPfDRcrjrAWmD/VrMzIh983R2hncvI44tfEZauI=}"
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
HELPER_RESOURCE_DIR="${PACKAGE_DIR}/HelperResources"
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
  trap restore_signing_search_list EXIT
}

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
  APP_VERSION="${VEX_NATIVE_VERSION:-${APP_VERSION}}"
  APP_BUILD="${VEX_NATIVE_BUILD:-${APP_BUILD}}"
  SPARKLE_FEED_URL="${VEX_SPARKLE_FEED_URL:-${SPARKLE_FEED_URL}}"
  SPARKLE_PUBLIC_ED_KEY="${VEX_SPARKLE_PUBLIC_ED_KEY:-${SPARKLE_PUBLIC_ED_KEY}}"
  # An inherited caller identity takes precedence over local release defaults.
  if [[ "${CODESIGN_IDENTITY_EXPLICIT}" == "0" && -n "${VEX_CODESIGN_IDENTITY+x}" ]]; then
    CODESIGN_IDENTITY="${VEX_CODESIGN_IDENTITY}"
    CODESIGN_IDENTITY_EXPLICIT=1
  fi
fi

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

if [[ ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "VEX_NATIVE_BUILD must be numeric; got '${APP_BUILD}'" >&2
  exit 1
fi
if [[ "${SPARKLE_FEED_URL}" != https://* ]]; then
  echo "VEX_SPARKLE_FEED_URL must use HTTPS; got '${SPARKLE_FEED_URL}'" >&2
  exit 1
fi
printf '%s\n' 'import base64
import sys

try:
    decoded = base64.b64decode(sys.argv[1], validate=True)
except ValueError as error:
    raise SystemExit(f"Sparkle public Ed25519 key is not valid base64: {error}")
if len(decoded) != 32:
    raise SystemExit("Sparkle public Ed25519 key must decode to 32 bytes")' | python3 - "${SPARKLE_PUBLIC_ED_KEY}"

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  CODESIGN_ARGS=(--force --sign -)
else
  # This pinned local identity has no Apple TeamIdentifier. Hardened-runtime
  # library validation would reject its bundled Sparkle framework at launch.
  # Retain the existing local-development runtime model; Apple releases keep HR.
  if [[ "${CODESIGN_IDENTITY}" == "C6FD1853A177FBCFB04C5D4F78FBE405777B3A3E" \
        || "${CODESIGN_IDENTITY}" == "VEX Self-Signed Application" ]]; then
    CODESIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY}")
  else
    CODESIGN_ARGS=(--force --options runtime --sign "${CODESIGN_IDENTITY}")
  fi
  [[ -z "${CODESIGN_KEYCHAIN}" ]] || CODESIGN_ARGS+=(--keychain "${CODESIGN_KEYCHAIN}")
  if [[ "${CODESIGN_TIMESTAMP}" == "none" ]]; then
    CODESIGN_ARGS+=(--timestamp=none)
  else
    CODESIGN_ARGS+=(--timestamp)
  fi
fi

# Sparkle 2.9.6 is pinned in macos-native/Package.swift. Sign every executable
# and nested bundle in its shipped Versions/B layout before signing the framework
# and outer app. `--deep` is verification-only: using it while signing can hide
# an incorrectly signed nested updater from the release build.
sign_native_macos_bundle() {
  local app_dir="$1"
  local framework="${app_dir}/Contents/Frameworks/Sparkle.framework"
  local version_dir="${framework}/Versions/B"
  local resource
  local xpc

  for resource in awg amneziawg-go vex-helper; do
    codesign --remove-signature "${app_dir}/Contents/Resources/resources/${resource}" 2>/dev/null || true
    codesign "${CODESIGN_ARGS[@]}" "${app_dir}/Contents/Resources/resources/${resource}"
    codesign --verify --strict "${app_dir}/Contents/Resources/resources/${resource}"
  done

  # Mach-O executables must be signed before their containing application/XPC
  # bundles. Keep this list explicit so a Sparkle layout change fails closed.
  for code in \
    "${version_dir}/Autoupdate" \
    "${version_dir}/Sparkle" \
    "${version_dir}/Updater.app/Contents/MacOS/Updater"; do
    [[ -f "${code}" ]] || { echo "Missing pinned Sparkle executable: ${code}" >&2; return 1; }
    codesign "${CODESIGN_ARGS[@]}" "${code}"
  done
  codesign "${CODESIGN_ARGS[@]}" "${version_dir}/Updater.app"

  for xpc in Downloader Installer; do
    local xpc_bundle="${version_dir}/XPCServices/${xpc}.xpc"
    local xpc_executable="${xpc_bundle}/Contents/MacOS/${xpc}"
    [[ -f "${xpc_executable}" ]] || { echo "Missing pinned Sparkle XPC executable: ${xpc_executable}" >&2; return 1; }
    codesign "${CODESIGN_ARGS[@]}" "${xpc_executable}"
    codesign "${CODESIGN_ARGS[@]}" "${xpc_bundle}"
  done

  codesign "${CODESIGN_ARGS[@]}" "${framework}"
  codesign "${CODESIGN_ARGS[@]}" "${app_dir}"
  codesign --verify --deep --strict "${app_dir}"
}

# An operator may explicitly provide a public trust-anchor dictionary for a release.
# The default deliberately bundles nothing: a missing resource fails closed in the
# verifier. This never reads private keys, keychains, or production services.
package_native_vpn_profile_public_keys() {
  local app_dir="$1"
  local source="${VEX_NATIVE_VPN_PROFILE_PUBLIC_KEYS_FILE:-}"
  [[ -z "${source}" ]] && return 0
  printf '%s\n' 'import base64
import json
import os
import stat
import sys

source, destination = sys.argv[1:]
try:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(source, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("not a regular file")
        chunks = []
        remaining = 64 * 1024 + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError("input changed during read")
    raw = b"".join(chunks)
    if not raw or len(raw) > 64 * 1024 or len(raw) != before.st_size:
        raise ValueError("invalid size")
    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key id")
            result[key] = value
        return result
    anchors = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicates)
    if not isinstance(anchors, dict) or not 1 <= len(anchors) <= 8:
        raise ValueError("must contain 1 to 8 anchors")
    for key_id, encoded in anchors.items():
        if not isinstance(key_id, str) or not key_id or len(key_id.encode("utf-8")) > 128:
            raise ValueError("invalid key id")
        if not isinstance(encoded, str):
            raise ValueError("invalid public key")
        der = base64.b64decode(encoded, validate=True)
        if base64.b64encode(der).decode("ascii") != encoded:
            raise ValueError("non-canonical public key encoding")
        # Strict SubjectPublicKeyInfo for id-ecPublicKey / prime256v1 only.
        expected_prefix = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
        if len(der) != 91 or not der.startswith(expected_prefix) or der[-65] != 4:
            raise ValueError("not a P-256 SPKI public key")
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    with open(destination, "xb") as output:
        output.write(raw)
except (OSError, UnicodeError, ValueError, json.JSONDecodeError, base64.binascii.Error):
    # Do not echo source paths or data: release logs must not disclose input details.
    raise SystemExit("Invalid native VPN profile public-key resource")' | /usr/bin/python3 - "${source}" "${app_dir}/Contents/Resources/native-vpn-profile-public-keys.json"
  # Use the same platform CryptoKit parser as the verifier to reject malformed
  # P-256 points that merely resemble SPKI DER. Keep compiler diagnostics out of
  # release logs because they may include operator-provided paths.
  if ! printf '%s\n' 'import CryptoKit
import Foundation

let source = CommandLine.arguments[1]
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: source))
    guard let anchors = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
        throw CocoaError(.coderReadCorrupt)
    }
    for (_, value) in anchors {
        guard let der = Data(base64Encoded: value) else { throw CocoaError(.coderReadCorrupt) }
        _ = try P256.Signing.PublicKey(derRepresentation: der)
    }
} catch { exit(1) }' | /usr/bin/swift - "${app_dir}/Contents/Resources/native-vpn-profile-public-keys.json" >/dev/null 2>&1
  then
    rm -f "${app_dir}/Contents/Resources/native-vpn-profile-public-keys.json"
    echo "Invalid native VPN profile public-key resource" >&2
    return 1
  fi
}

# A test-only entry point exercises public-resource packaging and signing order
# with fake tools; it never builds, launches, installs, or contacts keychains/network.
if [[ "${VEX_MACOS_SIGNING_TEST_ONLY:-0}" == "1" ]]; then
  : "${VEX_MACOS_SIGNING_TEST_APP_DIR:?VEX_MACOS_SIGNING_TEST_APP_DIR is required}"
  package_native_vpn_profile_public_keys "${VEX_MACOS_SIGNING_TEST_APP_DIR}"
  sign_native_macos_bundle "${VEX_MACOS_SIGNING_TEST_APP_DIR}"
  exit 0
fi

cd "${PACKAGE_DIR}"
export VEX_CODESIGN_IDENTITY="${CODESIGN_IDENTITY}"
export VEX_CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN}"
export VEX_CODESIGN_TIMESTAMP="${CODESIGN_TIMESTAMP}"
"${ROOT_DIR}/scripts/build_swift_macos_helper.sh"

APP_SCRATCH_ROOT="${PACKAGE_DIR}/.build-app"
build_app_arch() {
  local arch="$1"
  local triple="${arch}-apple-macosx15.0"
  local scratch="${APP_SCRATCH_ROOT}/${arch}"
  local build_args=(--package-path "${PACKAGE_DIR}" --scratch-path "${scratch}"
    --configuration "${VEX_MACOS_CONFIGURATION:-release}" --product "${APP_NAME}" --triple "${triple}")
  # errexit is disabled inside command substitution on macOS Bash. Explicitly
  # propagate failures, so an old executable can never masquerade as this build.
  /usr/bin/swift build "${build_args[@]}" >&2 || return 1
  local bin_dir
  bin_dir="$(/usr/bin/swift build "${build_args[@]}" --show-bin-path)" || return 1
  [[ -x "${bin_dir}/${APP_NAME}" ]] || return 1
  printf '%s\n' "${bin_dir}/${APP_NAME}"
}

arm_executable="$(build_app_arch arm64)"
x86_executable="$(build_app_arch x86_64)"
if [[ ! -x "${arm_executable}" || ! -x "${x86_executable}" ]]; then
  echo "App build did not produce both architecture binaries." >&2
  exit 1
fi
mkdir -p "${APP_SCRATCH_ROOT}"
EXECUTABLE="${APP_SCRATCH_ROOT}/${APP_NAME}-universal"
/usr/bin/lipo -create "${arm_executable}" "${x86_executable}" -output "${EXECUTABLE}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
if ! otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
fi

SPARKLE_FRAMEWORK="$(dirname "${arm_executable}")/Sparkle.framework"
if [[ -n "${SPARKLE_FRAMEWORK}" && -d "${SPARKLE_FRAMEWORK}" ]]; then
  ditto "${SPARKLE_FRAMEWORK}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
else
  echo "Missing Sparkle.framework for the universal app build." >&2
  exit 1
fi

RESOURCE_BUNDLE="$(dirname "${arm_executable}")/${APP_NAME}_${APP_NAME}.bundle"
if [[ -n "${RESOURCE_BUNDLE}" && -d "${RESOURCE_BUNDLE}" ]]; then
  cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/"
else
  echo "Missing SwiftPM resource bundle for ${APP_NAME}" >&2
  exit 1
fi

package_native_vpn_profile_public_keys "${APP_DIR}"

mkdir -p "${APP_DIR}/Contents/Resources/resources"
for resource in install-vex-vpn-helper.sh awg amneziawg-go awg-quick.sh vex-helper helper-version; do
  if [[ -f "${HELPER_RESOURCE_DIR}/${resource}" ]]; then
    cp "${HELPER_RESOURCE_DIR}/${resource}" "${APP_DIR}/Contents/Resources/resources/${resource}"
  else
    echo "Missing helper resource: ${resource}" >&2
    exit 1
  fi
done
chmod 755 "${APP_DIR}/Contents/Resources/resources/install-vex-vpn-helper.sh" \
  "${APP_DIR}/Contents/Resources/resources/awg" \
  "${APP_DIR}/Contents/Resources/resources/amneziawg-go" \
  "${APP_DIR}/Contents/Resources/resources/awg-quick.sh" \
  "${APP_DIR}/Contents/Resources/resources/vex-helper"
chmod 644 "${APP_DIR}/Contents/Resources/resources/helper-version"

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"

printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '  <key>CFBundleDevelopmentRegion</key>' \
  '  <string>en</string>' \
  '  <key>CFBundleExecutable</key>' \
  "  <string>${APP_NAME}</string>" \
  '  <key>CFBundleIdentifier</key>' \
  '  <string>app.vex.vpn.native</string>' \
  '  <key>CFBundleInfoDictionaryVersion</key>' \
  '  <string>6.0</string>' \
  '  <key>CFBundleName</key>' \
  '  <string>VEX Native</string>' \
  '  <key>CFBundleIconFile</key>' \
  '  <string>VEXNative</string>' \
  '  <key>CFBundlePackageType</key>' \
  '  <string>APPL</string>' \
  '  <key>CFBundleURLTypes</key>' \
  '  <array>' \
  '    <dict>' \
  '      <key>CFBundleURLName</key>' \
  '      <string>VEX Auth</string>' \
  '      <key>CFBundleURLSchemes</key>' \
  '      <array>' \
  '        <string>vexguard</string>' \
  '        <string>vex</string>' \
  '      </array>' \
  '    </dict>' \
  '  </array>' \
  '  <key>CFBundleShortVersionString</key>' \
  "  <string>$(xml_escape "${APP_VERSION}")</string>" \
  '  <key>CFBundleVersion</key>' \
  "  <string>$(xml_escape "${APP_BUILD}")</string>" \
  '  <key>LSMinimumSystemVersion</key>' \
  '  <string>15.0</string>' \
  '  <key>LSApplicationCategoryType</key>' \
  '  <string>public.app-category.utilities</string>' \
  '  <key>NSHighResolutionCapable</key>' \
  '  <true/>' \
  '  <key>SUFeedURL</key>' \
  "  <string>$(xml_escape "${SPARKLE_FEED_URL}")</string>" \
  '  <key>SUPublicEDKey</key>' \
  "  <string>$(xml_escape "${SPARKLE_PUBLIC_ED_KEY}")</string>" \
  '  <key>SUEnableAutomaticChecks</key>' \
  '  <true/>' \
  '  <key>SUAllowsAutomaticUpdates</key>' \
  '  <true/>' \
  '  <key>SUAutomaticallyUpdate</key>' \
  '  <false/>' \
  '  <key>SUVerifyUpdateBeforeExtraction</key>' \
  '  <true/>' \
  '</dict>' \
  '</plist>' >"${APP_DIR}/Contents/Info.plist"

sign_native_macos_bundle "${APP_DIR}"

# Runs before any GUI/helper initialization and resolves packaged resources only.
"${APP_DIR}/Contents/MacOS/${APP_NAME}" --resource-bundle-probe

echo "${APP_DIR}"
restore_signing_search_list
trap - EXIT

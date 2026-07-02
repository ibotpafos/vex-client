#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/macos-native"
BUILD_DIR="${PACKAGE_DIR}/build"
RELEASE_DIR="${VEX_SPARKLE_RELEASE_DIR:-${BUILD_DIR}/sparkle-release}"
ARCHIVES_DIR="${RELEASE_DIR}/archives"
APP_NAME="VEXNativeMac"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"
APP_VERSION="${VEX_NATIVE_VERSION:-}"
APP_BUILD="${VEX_NATIVE_BUILD:-}"
DOWNLOAD_URL_PREFIX="${VEX_SPARKLE_DOWNLOAD_URL_PREFIX:-https://vexguard.app/downloads/native-macos/}"
SPARKLE_TOOLS_DIR="${PACKAGE_DIR}/.build/artifacts/sparkle/Sparkle/bin"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_sha256_sidecar() {
  local path="$1"
  local hash
  hash="$(sha256_file "${path}")"
  printf '%s  %s\n' "${hash}" "$(basename "${path}")" >"${path}.sha256"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "${INFO_PLIST}"
}

validate_info_plist() {
  local bundle_version short_version public_key feed_url
  bundle_version="$(plist_value CFBundleVersion)"
  short_version="$(plist_value CFBundleShortVersionString)"
  public_key="$(plist_value SUPublicEDKey)"
  feed_url="$(plist_value SUFeedURL)"

  if [[ "${bundle_version}" != "${APP_BUILD}" ]]; then
    echo "Info.plist CFBundleVersion mismatch: ${bundle_version} != ${APP_BUILD}" >&2
    exit 1
  fi
  if [[ "${short_version}" != "${APP_VERSION}" ]]; then
    echo "Info.plist CFBundleShortVersionString mismatch: ${short_version} != ${APP_VERSION}" >&2
    exit 1
  fi
  if [[ "${public_key}" != "${VEX_SPARKLE_PUBLIC_ED_KEY}" ]]; then
    echo "Info.plist SUPublicEDKey does not match VEX_SPARKLE_PUBLIC_ED_KEY" >&2
    exit 1
  fi
  if [[ "${feed_url}" != "${VEX_SPARKLE_FEED_URL:-https://vexguard.app/downloads/native-macos/appcast.xml}" ]]; then
    echo "Info.plist SUFeedURL mismatch: ${feed_url}" >&2
    exit 1
  fi
}

validate_appcast() {
  local appcast="$1"
  python3 - "$appcast" "${APP_VERSION}" "${APP_BUILD}" "${DOWNLOAD_URL_PREFIX%/}/" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, expected_version, expected_build, expected_prefix = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(appcast_path).getroot()
items = root.findall("./channel/item")
if not items:
    raise SystemExit("appcast has no items")
enclosure = items[0].find("enclosure")
if enclosure is None:
    raise SystemExit("latest appcast item has no enclosure")

url = enclosure.attrib.get("url", "")
version_node = items[0].find("sparkle:version", ns)
short_version_node = items[0].find("sparkle:shortVersionString", ns)
version = version_node.text if version_node is not None else ""
short_version = short_version_node.text if short_version_node is not None else ""
signature = enclosure.attrib.get(f"{{{ns['sparkle']}}}edSignature", "")

if version != expected_build:
    raise SystemExit(f"appcast sparkle:version mismatch: {version} != {expected_build}")
if short_version != expected_version:
    raise SystemExit(f"appcast sparkle:shortVersionString mismatch: {short_version} != {expected_version}")
if not signature:
    raise SystemExit("appcast enclosure is missing sparkle:edSignature")
if not url.startswith(expected_prefix):
    raise SystemExit(f"appcast download url does not use expected prefix: {url}")

print(url)
PY
}

maybe_notarize_app() {
  if [[ "${VEX_NOTARIZE:-0}" != "1" ]]; then
    return
  fi
  if [[ "${VEX_CODESIGN_IDENTITY:--}" == "-" ]]; then
    echo "VEX_NOTARIZE=1 requires VEX_CODESIGN_IDENTITY with Developer ID Application identity." >&2
    exit 2
  fi
  require_command xcrun

  local profile_args=()
  if [[ -n "${VEX_NOTARY_PROFILE:-}" ]]; then
    profile_args=(--keychain-profile "${VEX_NOTARY_PROFILE}")
  else
    if [[ -z "${VEX_NOTARY_APPLE_ID:-}" || -z "${VEX_NOTARY_TEAM_ID:-}" || -z "${VEX_NOTARY_PASSWORD:-}" ]]; then
      echo "Set VEX_NOTARY_PROFILE or VEX_NOTARY_APPLE_ID/VEX_NOTARY_TEAM_ID/VEX_NOTARY_PASSWORD for notarization." >&2
      exit 2
    fi
    profile_args=(--apple-id "${VEX_NOTARY_APPLE_ID}" --team-id "${VEX_NOTARY_TEAM_ID}" --password "${VEX_NOTARY_PASSWORD}")
  fi

  local notary_zip="${RELEASE_DIR}/${APP_NAME}-${APP_VERSION}-${APP_BUILD}-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${notary_zip}"
  xcrun notarytool submit "${notary_zip}" "${profile_args[@]}" --wait
  xcrun stapler staple "${APP_DIR}"
  rm -f "${notary_zip}"
}

write_release_manifest() {
  local zip_path="$1"
  local appcast_path="$2"
  local download_url="$3"
  local manifest_path="${ARCHIVES_DIR}/release-manifest.json"
  local zip_sha appcast_sha signing_state notarized_state gatekeeper_ready_state distribution_mode
  zip_sha="$(sha256_file "${zip_path}")"
  appcast_sha="$(sha256_file "${appcast_path}")"
  signing_state="${VEX_CODESIGN_IDENTITY:--}"
  notarized_state="False"
  gatekeeper_ready_state="False"
  distribution_mode="sparkle-ad-hoc"
  if [[ "${VEX_NOTARIZE:-0}" == "1" ]]; then
    notarized_state="True"
    gatekeeper_ready_state="True"
    distribution_mode="sparkle-developer-id-notarized"
  elif [[ "${signing_state}" != "-" ]]; then
    distribution_mode="sparkle-developer-id-not-notarized"
  fi

  python3 - "${manifest_path}" <<PY
import json
from pathlib import Path

manifest = {
    "product": "VEX Native macOS",
    "bundleIdentifier": "app.vex.vpn.native",
    "version": "${APP_VERSION}",
    "build": "${APP_BUILD}",
    "feedURL": "${VEX_SPARKLE_FEED_URL:-https://vexguard.app/downloads/native-macos/appcast.xml}",
    "downloadURL": "${download_url}",
    "archive": "$(basename "${zip_path}")",
    "archiveSHA256": "${zip_sha}",
    "archiveSHA256Sidecar": "$(basename "${zip_path}").sha256",
    "appcast": "$(basename "${appcast_path}")",
    "appcastSHA256": "${appcast_sha}",
    "appcastSHA256Sidecar": "$(basename "${appcast_path}").sha256",
    "sparklePublicEDKey": "${VEX_SPARKLE_PUBLIC_ED_KEY}",
    "codesignIdentity": "${signing_state}",
    "distributionMode": "${distribution_mode}",
    "notarized": ${notarized_state},
    "gatekeeperReady": ${gatekeeper_ready_state},
    "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
}
Path("${manifest_path}").write_text(json.dumps(manifest, indent=2) + "\n")
PY
}

require_command awk
require_command basename
require_command codesign
require_command ditto
require_command python3
require_command shasum

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
  APP_VERSION="${VEX_NATIVE_VERSION:-${APP_VERSION}}"
  APP_BUILD="${VEX_NATIVE_BUILD:-${APP_BUILD}}"
  DOWNLOAD_URL_PREFIX="${VEX_SPARKLE_DOWNLOAD_URL_PREFIX:-${DOWNLOAD_URL_PREFIX}}"
fi

if [[ -z "${APP_VERSION}" ]]; then
  echo "Set VEX_NATIVE_VERSION, for example VEX_NATIVE_VERSION=0.1.1" >&2
  exit 1
fi

if [[ -z "${APP_BUILD}" || ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "Set numeric VEX_NATIVE_BUILD, for example VEX_NATIVE_BUILD=2" >&2
  exit 1
fi

if [[ -z "${VEX_SPARKLE_PUBLIC_ED_KEY:-}" && "${VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS:-0}" == "1" ]]; then
  mkdir -p "${RELEASE_DIR}"
  EPHEMERAL_KEY_FILE="${RELEASE_DIR}/ephemeral-sparkle-private-key.txt"
  KEY_OUTPUT="$(swift -e 'import CryptoKit; let key = Curve25519.Signing.PrivateKey(); print(key.rawRepresentation.base64EncodedString()); print(key.publicKey.rawRepresentation.base64EncodedString())')"
  VEX_SPARKLE_PRIVATE_ED_KEY_FILE="${EPHEMERAL_KEY_FILE}"
  VEX_SPARKLE_PUBLIC_ED_KEY="$(printf '%s\n' "${KEY_OUTPUT}" | sed -n '2p')"
  printf '%s\n' "${KEY_OUTPUT}" | sed -n '1p' >"${EPHEMERAL_KEY_FILE}"
  echo "Using ephemeral Sparkle EdDSA key for local release smoke test. Do not publish this appcast." >&2
fi

if [[ -z "${VEX_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "Set VEX_SPARKLE_PUBLIC_ED_KEY in .env.sparkle.local or the environment." >&2
  echo "Generate it with: macos-native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account app.vex.vpn.native" >&2
  exit 1
fi

if [[ "${VEX_SPARKLE_PRODUCTION:-0}" == "1" ]]; then
  if [[ "${VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS:-0}" == "1" ]]; then
    echo "VEX_SPARKLE_PRODUCTION=1 cannot use VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS=1." >&2
    exit 2
  fi
  if [[ -z "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]]; then
    echo "VEX_SPARKLE_PRODUCTION=1 requires VEX_SPARKLE_PRIVATE_ED_KEY_FILE." >&2
    exit 2
  fi
  if [[ "${VEX_SPARKLE_REQUIRE_DEVELOPER_ID:-0}" == "1" && "${VEX_CODESIGN_IDENTITY:--}" == "-" ]]; then
    echo "VEX_SPARKLE_REQUIRE_DEVELOPER_ID=1 requires VEX_CODESIGN_IDENTITY with Developer ID Application identity." >&2
    exit 2
  fi
  if [[ "${VEX_CODESIGN_IDENTITY:--}" == "-" ]]; then
    echo "Building production Sparkle appcast with ad-hoc app signing. Updates will work after the app is trusted locally, but Gatekeeper friction remains." >&2
  fi
fi

export VEX_NATIVE_VERSION="${APP_VERSION}"
export VEX_NATIVE_BUILD="${APP_BUILD}"
export VEX_SPARKLE_PUBLIC_ED_KEY

"${ROOT_DIR}/scripts/build_native_macos_app.sh"
validate_info_plist

SIGN_TOOL="${SPARKLE_TOOLS_DIR}/sign_update"
APPCAST_TOOL="${SPARKLE_TOOLS_DIR}/generate_appcast"
if [[ ! -x "${SIGN_TOOL}" || ! -x "${APPCAST_TOOL}" ]]; then
  echo "Missing Sparkle tools. Run scripts/build_native_macos_app.sh once to resolve Sparkle." >&2
  exit 1
fi

rm -rf "${ARCHIVES_DIR}"
mkdir -p "${ARCHIVES_DIR}"

maybe_notarize_app
codesign --verify --deep --strict "${APP_DIR}"

ZIP_NAME="${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"
ZIP_PATH="${ARCHIVES_DIR}/${ZIP_NAME}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

RELEASE_NOTES="${ARCHIVES_DIR}/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.md"
cat >"${RELEASE_NOTES}" <<NOTES
# VEX Native ${APP_VERSION}

Native macOS update delivered through Sparkle 2.
NOTES

APPCAST_ARGS=(
  "--download-url-prefix" "${DOWNLOAD_URL_PREFIX%/}/"
  "--embed-release-notes"
  "--maximum-versions" "5"
  "-o" "${ARCHIVES_DIR}/appcast.xml"
)

if [[ -n "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]]; then
  if [[ ! -f "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}" ]]; then
    echo "VEX_SPARKLE_PRIVATE_ED_KEY_FILE does not exist: ${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}" >&2
    exit 1
  fi
  APPCAST_ARGS+=("--ed-key-file" "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}")
else
  APPCAST_ARGS+=("--account" "${VEX_SPARKLE_KEY_ACCOUNT:-app.vex.vpn.native}")
fi

"${APPCAST_TOOL}" "${APPCAST_ARGS[@]}" "${ARCHIVES_DIR}"

APPCAST_PATH="${ARCHIVES_DIR}/appcast.xml"
DOWNLOAD_URL="$(validate_appcast "${APPCAST_PATH}")"
write_sha256_sidecar "${ZIP_PATH}"
write_sha256_sidecar "${APPCAST_PATH}"
write_release_manifest "${ZIP_PATH}" "${APPCAST_PATH}" "${DOWNLOAD_URL}"

echo "Sparkle archive: ${ZIP_PATH}"
echo "Sparkle appcast: ${APPCAST_PATH}"
echo "Sparkle manifest: ${ARCHIVES_DIR}/release-manifest.json"

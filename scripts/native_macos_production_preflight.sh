#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${VEX_NATIVE_APP_PATH:-${ROOT_DIR}/macos-native/build/VEXNativeMac.app}"
PKG_PATH="${VEX_NATIVE_PKG_PATH:-}"
SPARKLE_ARCHIVES_DIR="${VEX_SPARKLE_ARCHIVES_DIR:-${ROOT_DIR}/macos-native/build/sparkle-release/archives}"
PRODUCTION="${VEX_NATIVE_PRODUCTION:-0}"
REQUIRE_DEVELOPER_ID="${VEX_NATIVE_REQUIRE_DEVELOPER_ID:-0}"
DISPLAY_MODE="${VEX_NATIVE_DISTRIBUTION_MODE:-internal}"
MAX_MINIMUM_SYSTEM_MAJOR="${VEX_NATIVE_MAX_MINIMUM_SYSTEM_MAJOR:-14}"
VERIFY_INSTALLED_RUNTIME="${VEX_NATIVE_VERIFY_INSTALLED_RUNTIME:-0}"

fail() {
  echo "preflight failed: $*" >&2
  exit 1
}

warn() {
  echo "preflight warning: $*" >&2
}

require_file() {
  [[ -e "$1" ]] || fail "missing $1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

require_file "${APP_PATH}"
require_file "${APP_PATH}/Contents/Info.plist"
require_file "${APP_PATH}/Contents/MacOS/VEXNativeMac"

bundle_id="$(plist_value "${APP_PATH}/Contents/Info.plist" CFBundleIdentifier)"
[[ "${bundle_id}" == "app.vex.vpn.native" ]] || fail "unexpected bundle id: ${bundle_id}"

minimum_system="$(plist_value "${APP_PATH}/Contents/Info.plist" LSMinimumSystemVersion)"
minimum_major="${minimum_system%%.*}"
[[ "${minimum_major}" =~ ^[0-9]+$ ]] || fail "invalid LSMinimumSystemVersion: ${minimum_system}"
if (( minimum_major > MAX_MINIMUM_SYSTEM_MAJOR )); then
  fail "LSMinimumSystemVersion ${minimum_system} is above production max ${MAX_MINIMUM_SYSTEM_MAJOR}.x"
fi

sparkle_key="$(plist_value "${APP_PATH}/Contents/Info.plist" SUPublicEDKey)"
if [[ -z "${sparkle_key}" || "${sparkle_key}" == "VEX_SPARKLE_PUBLIC_ED_KEY_NOT_SET" ]]; then
  fail "SUPublicEDKey is missing or placeholder"
fi

sparkle_feed="$(plist_value "${APP_PATH}/Contents/Info.plist" SUFeedURL)"
[[ "${sparkle_feed}" == https://* ]] || fail "SUFeedURL must be https: ${sparkle_feed}"

resources_dir="${APP_PATH}/Contents/Resources/resources"
for resource in install-vex-vpn-helper.sh awg amneziawg-go vex-helper; do
  require_file "${resources_dir}/${resource}"
  [[ -x "${resources_dir}/${resource}" ]] || fail "resource is not executable: ${resource}"
done
require_file "${resources_dir}/helper-version"
[[ -r "${resources_dir}/helper-version" ]] || fail "resource is not readable: helper-version"

codesign --verify --deep --strict "${APP_PATH}" || fail "codesign verification failed"

signature_details="$(codesign -dvvv "${APP_PATH}" 2>&1 || true)"
if grep -q "Signature=adhoc" <<<"${signature_details}"; then
  if [[ "${REQUIRE_DEVELOPER_ID}" == "1" ]]; then
    fail "app is ad-hoc signed; Developer ID signature required"
  fi
  if [[ "${DISPLAY_MODE}" == "internal" ]]; then
    echo "preflight note: app is ad-hoc signed as expected for internal distribution without Apple Developer ID"
  else
    warn "app is ad-hoc signed; Gatekeeper distribution still requires Developer ID + notarization"
  fi
fi

if [[ -n "${PKG_PATH}" ]]; then
  require_file "${PKG_PATH}"
  pkgutil --check-signature "${PKG_PATH}" >/dev/null 2>&1 || {
    if [[ "${REQUIRE_DEVELOPER_ID}" == "1" ]]; then
      fail "pkg signature check failed: ${PKG_PATH}"
    fi
    if [[ "${DISPLAY_MODE}" == "internal" ]]; then
      echo "preflight note: pkg is unsigned as expected for internal distribution without Apple Developer ID"
    else
      warn "pkg is unsigned or not trusted: ${PKG_PATH}"
    fi
  }
fi

if [[ -d "${SPARKLE_ARCHIVES_DIR}" ]]; then
  require_file "${SPARKLE_ARCHIVES_DIR}/appcast.xml"
  require_file "${SPARKLE_ARCHIVES_DIR}/appcast.xml.sha256"
  require_file "${SPARKLE_ARCHIVES_DIR}/release-manifest.json"
  python3 - "${SPARKLE_ARCHIVES_DIR}/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(path).getroot()
items = root.findall("./channel/item")
if not items:
    raise SystemExit("appcast has no items")
enclosure = items[0].find("enclosure")
if enclosure is None:
    raise SystemExit("latest item has no enclosure")
if not enclosure.attrib.get(f"{{{ns['sparkle']}}}edSignature"):
    raise SystemExit("latest enclosure is missing sparkle:edSignature")
if not enclosure.attrib.get("url", "").startswith("https://"):
    raise SystemExit("latest enclosure url must be https")
PY
elif [[ "${PRODUCTION}" == "1" ]]; then
  fail "Sparkle archives directory is missing: ${SPARKLE_ARCHIVES_DIR}"
else
  warn "Sparkle archives directory not found; skipping appcast validation"
fi

if [[ "${VERIFY_INSTALLED_RUNTIME}" == "1" ]]; then
  STRICT=1 APP_PATH="${VEX_NATIVE_INSTALLED_APP_PATH:-/Applications/VEX Native.app}" \
    bash "${ROOT_DIR}/scripts/verify_native_macos_runtime.sh"
fi

echo "native macOS production preflight passed: ${APP_PATH}"

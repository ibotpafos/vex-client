#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPN_REPO="${VEX_VPN_REPO:-/Users/ibotpafos/projects/VPN}"
RUN_CHECKS="${RUN_CHECKS:-1}"
RUN_DEPLOY="${RUN_DEPLOY:-1}"
RUN_LIVE_VERIFY="${RUN_LIVE_VERIFY:-1}"
ALLOW_DIRTY_DEPLOY="${ALLOW_DIRTY_DEPLOY:-1}"
ALLOW_NO_UPSTREAM_DEPLOY="${ALLOW_NO_UPSTREAM_DEPLOY:-1}"
NATIVE_DOWNLOAD_DIR="${VPN_REPO}/web/public/downloads/native-macos"
VPN_RELEASE_DIR="${VPN_RELEASE_DIR:-dist/native-macos}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 2
  fi
}

load_env_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${path}"
    set +a
  fi
}

resolve_next_release() {
  python3 - "$VPN_REPO" "${VEX_NATIVE_VERSION:-}" "${VEX_NATIVE_BUILD:-}" <<'PY'
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

vpn_repo, provided_version, provided_build = sys.argv[1:]
if provided_version and provided_build:
    print(provided_version)
    print(provided_build)
    raise SystemExit(0)

version = ""
build = 0
manifest = Path(vpn_repo) / "web/public/downloads/native-macos/release-manifest.json"
if manifest.exists():
    data = json.loads(manifest.read_text())
    version = str(data.get("version") or "")
    build = int(str(data.get("build") or "0"))

if not version or build <= 0:
    try:
        with urllib.request.urlopen("https://vexguard.app/downloads/native-macos/appcast.xml", timeout=8) as response:
            root = ET.fromstring(response.read())
        ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        item = root.find("./channel/item")
        if item is not None:
            version = item.findtext("sparkle:shortVersionString", default="", namespaces=ns)
            build = int(item.findtext("sparkle:version", default="0", namespaces=ns))
    except Exception:
        pass

if not version:
    version = "0.1.36"
if build <= 0:
    build = 36

if provided_version:
    next_version = provided_version
else:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        raise SystemExit(f"cannot auto-bump version: {version}")
    major, minor, patch = map(int, match.groups())
    next_version = f"{major}.{minor}.{patch + 1}"

next_build = int(provided_build) if provided_build else build + 1
print(next_version)
print(next_build)
PY
}

validate_live_appcast() {
  python3 - "${VEX_NATIVE_VERSION}" "${VEX_NATIVE_BUILD}" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

expected_version, expected_build = sys.argv[1:]
url = "https://vexguard.app/downloads/native-macos/appcast.xml"
with urllib.request.urlopen(url, timeout=12) as response:
    body = response.read()
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.fromstring(body)
item = root.find("./channel/item")
if item is None:
    raise SystemExit("live appcast has no item")
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("live appcast item has no enclosure")
version = item.findtext("sparkle:shortVersionString", default="", namespaces=ns)
build = item.findtext("sparkle:version", default="", namespaces=ns)
signature = enclosure.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
if version != expected_version or build != expected_build:
    raise SystemExit(f"live appcast mismatch: {version} ({build}) != {expected_version} ({expected_build})")
if not signature:
    raise SystemExit("live appcast enclosure is missing sparkle:edSignature")
print(f"live native macOS appcast ok: {version} ({build})")
PY
}

require_command bash
require_command codesign
require_command python3
require_command shasum
require_command swift

if [[ ! -d "${VPN_REPO}" ]]; then
  echo "VPN repo not found: ${VPN_REPO}" >&2
  exit 2
fi

load_env_file "${ROOT_DIR}/.env.sparkle.local"
if [[ "${VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS:-0}" == "1" ]]; then
  echo "autonomous release refuses ephemeral Sparkle keys" >&2
  exit 2
fi
if [[ -z "${VEX_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "VEX_SPARKLE_PUBLIC_ED_KEY is required" >&2
  exit 2
fi
if [[ -z "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]]; then
  echo "VEX_SPARKLE_PRIVATE_ED_KEY_FILE is required" >&2
  exit 2
fi
require_file "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}"

release_values="$(resolve_next_release)"
export VEX_NATIVE_VERSION="$(printf '%s\n' "${release_values}" | sed -n '1p')"
export VEX_NATIVE_BUILD="$(printf '%s\n' "${release_values}" | sed -n '2p')"
export VEX_SPARKLE_PRODUCTION=1

echo "native macOS autonomous release: ${VEX_NATIVE_VERSION} (${VEX_NATIVE_BUILD})"

if [[ "${RUN_CHECKS}" == "1" ]]; then
  swift test --package-path "${ROOT_DIR}/macos-native"
fi

bash "${ROOT_DIR}/scripts/build_native_macos_internal_release.sh"
bash "${ROOT_DIR}/scripts/prepare_native_macos_deploy_bundle.sh"

mkdir -p "${NATIVE_DOWNLOAD_DIR}"
cp "${ROOT_DIR}/dist/native-macos/deploy/VEXNativeMac-${VEX_NATIVE_VERSION}-${VEX_NATIVE_BUILD}.zip" "${NATIVE_DOWNLOAD_DIR}/"
cp "${ROOT_DIR}/dist/native-macos/deploy/VEXNativeMac-${VEX_NATIVE_VERSION}-${VEX_NATIVE_BUILD}.zip.sha256" "${NATIVE_DOWNLOAD_DIR}/"
cp "${ROOT_DIR}/dist/native-macos/deploy/appcast.xml" "${NATIVE_DOWNLOAD_DIR}/"
cp "${ROOT_DIR}/dist/native-macos/deploy/appcast.xml.sha256" "${NATIVE_DOWNLOAD_DIR}/"
cp "${ROOT_DIR}/dist/native-macos/deploy/release-manifest.json" "${NATIVE_DOWNLOAD_DIR}/"

(
  cd "${VPN_REPO}"
  DOWNLOAD_SCOPE=native-macos ./scripts/check_release_metadata.sh
  DOWNLOAD_SCOPE=native-macos RELEASE_DIR="${VPN_RELEASE_DIR}" ./scripts/build_download_artifacts.sh
)

if [[ "${RUN_DEPLOY}" == "1" ]]; then
  (
    cd "${VPN_REPO}"
    env \
      ALLOW_DIRTY_DEPLOY="${ALLOW_DIRTY_DEPLOY}" \
      ALLOW_NO_UPSTREAM_DEPLOY="${ALLOW_NO_UPSTREAM_DEPLOY}" \
      DOWNLOAD_SCOPE=native-macos \
      DOWNLOAD_ARCHIVE="${VPN_RELEASE_DIR}/vex-downloads.tar.gz" \
      make production-downloads-deploy
  )
fi

if [[ "${RUN_LIVE_VERIFY}" == "1" && "${RUN_DEPLOY}" == "1" ]]; then
  validate_live_appcast
fi

echo "native macOS autonomous release complete: ${VEX_NATIVE_VERSION} (${VEX_NATIVE_BUILD})"

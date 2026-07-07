#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_CHECKS="${RUN_CHECKS:-1}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
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
  python3 - "${VEX_NATIVE_VERSION:-}" "${VEX_NATIVE_BUILD:-}" <<'PY'
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

provided_version, provided_build = sys.argv[1:]
if provided_version and provided_build:
    print(provided_version)
    print(provided_build)
    raise SystemExit(0)

version = ""
build = 0
manifest = Path("macos-native/build/sparkle-release/archives/release-manifest.json")
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
    version = "0.1.38"
if build <= 0:
    build = 38

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

require_command bash
require_command codesign
require_command python3
require_command shasum
require_command swift

cd "${ROOT_DIR}"
load_env_file "${ROOT_DIR}/.env.sparkle.local"

release_values="$(resolve_next_release)"
export VEX_NATIVE_VERSION="$(printf '%s\n' "${release_values}" | sed -n '1p')"
export VEX_NATIVE_BUILD="$(printf '%s\n' "${release_values}" | sed -n '2p')"
export VEX_SPARKLE_PRODUCTION=1

echo "native macOS local release: ${VEX_NATIVE_VERSION} (${VEX_NATIVE_BUILD})"

if [[ "${RUN_CHECKS}" == "1" ]]; then
  swift test --package-path "${ROOT_DIR}/macos-native"
fi

bash "${ROOT_DIR}/scripts/build_native_macos_internal_release.sh"
bash "${ROOT_DIR}/scripts/prepare_native_macos_deploy_bundle.sh"

echo "native macOS local release ready: ${ROOT_DIR}/dist/native-macos/deploy"

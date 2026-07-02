#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="${VEX_SPARKLE_ARCHIVES_DIR:-${ROOT_DIR}/macos-native/build/sparkle-release/archives}"
PKG_DIR="${VEX_NATIVE_PKG_DIR:-${ROOT_DIR}/macos-native/build/pkg}"
OUT_DIR="${VEX_NATIVE_DEPLOY_BUNDLE_DIR:-${ROOT_DIR}/dist/native-macos/deploy}"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

require_file "${ARCHIVES_DIR}/release-manifest.json"
require_file "${ARCHIVES_DIR}/appcast.xml"
require_file "${ARCHIVES_DIR}/appcast.xml.sha256"

archive_name="$(python3 - "${ARCHIVES_DIR}/release-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
archive = manifest.get("archive")
download = manifest.get("downloadURL", "")
if not archive:
    raise SystemExit("release-manifest.json has no archive")
if not download.endswith("/" + archive):
    raise SystemExit(f"downloadURL does not end with archive name: {download}")
print(archive)
PY
)"

require_file "${ARCHIVES_DIR}/${archive_name}"
require_file "${ARCHIVES_DIR}/${archive_name}.sha256"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

cp "${ARCHIVES_DIR}/appcast.xml" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/appcast.xml.sha256" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/release-manifest.json" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${archive_name}" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${archive_name}.sha256" "${OUT_DIR}/"

pkg_path="$(find "${PKG_DIR}" -maxdepth 1 -type f -name '*.pkg' -print | sort | tail -n 1 || true)"
if [[ -n "${pkg_path}" ]]; then
  cp "${pkg_path}" "${OUT_DIR}/"
fi

(
  cd "${OUT_DIR}"
  shasum -a 256 -c "${archive_name}.sha256"
  shasum -a 256 -c appcast.xml.sha256
)

echo "Native macOS deploy bundle ready: ${OUT_DIR}"
find "${OUT_DIR}" -maxdepth 1 -type f -print | sort

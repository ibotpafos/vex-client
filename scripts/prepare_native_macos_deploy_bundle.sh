#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="${VEX_SPARKLE_ARCHIVES_DIR:-${ROOT_DIR}/macos-native/build/sparkle-release/archives}"
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

artifact_names="$(python3 - "${ARCHIVES_DIR}/release-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
archive = manifest.get("archive")
package = manifest.get("package")
package_sha = manifest.get("packageSHA256")
download = manifest.get("downloadURL", "")
package_download = manifest.get("packageDownloadURL", "")
if not archive or not package or not package_sha:
    raise SystemExit("release-manifest.json must include archive, package, and packageSHA256")
if not download.endswith("/" + archive):
    raise SystemExit(f"downloadURL does not end with archive name: {download}")
if not package_download.endswith("/" + package):
    raise SystemExit(f"packageDownloadURL does not end with package name: {package_download}")
if not all(manifest.get(field) is True for field in ("appleDeveloperSigned", "notarized", "gatekeeperReady")):
    raise SystemExit("release-manifest.json is not Gatekeeper-ready")
print(archive)
print(package)
PY
)"
archive_name="$(printf '%s\n' "${artifact_names}" | sed -n '1p')"
package_name="$(printf '%s\n' "${artifact_names}" | sed -n '2p')"

require_file "${ARCHIVES_DIR}/${archive_name}"
require_file "${ARCHIVES_DIR}/${archive_name}.sha256"
require_file "${ARCHIVES_DIR}/${package_name}"
require_file "${ARCHIVES_DIR}/${package_name}.sha256"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

cp "${ARCHIVES_DIR}/appcast.xml" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/appcast.xml.sha256" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/release-manifest.json" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${archive_name}" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${archive_name}.sha256" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${package_name}" "${OUT_DIR}/"
cp "${ARCHIVES_DIR}/${package_name}.sha256" "${OUT_DIR}/"

(
  cd "${OUT_DIR}"
  shasum -a 256 -c "${archive_name}.sha256"
  shasum -a 256 -c "${package_name}.sha256"
  shasum -a 256 -c appcast.xml.sha256
)

echo "Native macOS deploy bundle ready: ${OUT_DIR}"
find "${OUT_DIR}" -maxdepth 1 -type f -print | sort

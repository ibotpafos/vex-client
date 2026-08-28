#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
fi
ARCHIVES_DIR="${VEX_SPARKLE_RELEASE_DIR:-${ROOT_DIR}/macos-native/build/sparkle-release}/archives"

fail() {
  echo "public release failed: $*" >&2
  exit 2
}

[[ "${VEX_CODESIGN_IDENTITY:-}" == Developer\ ID\ Application:* ]] \
  || fail "VEX_CODESIGN_IDENTITY must be a Developer ID Application identity"
[[ "${VEX_INSTALLER_SIGN_IDENTITY:-}" == Developer\ ID\ Installer:* ]] \
  || fail "VEX_INSTALLER_SIGN_IDENTITY must be a Developer ID Installer identity"
[[ "${VEX_NOTARIZE:-0}" == "1" ]] || fail "VEX_NOTARIZE=1 is required"
[[ -n "${VEX_SPARKLE_PUBLIC_ED_KEY:-}" ]] || fail "VEX_SPARKLE_PUBLIC_ED_KEY is required"
[[ -n "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]] \
  || fail "VEX_SPARKLE_PRIVATE_ED_KEY_FILE is required"

if [[ -z "${VEX_NOTARY_PROFILE:-}" ]] \
  && { [[ -z "${VEX_NOTARY_APPLE_ID:-}" ]] \
    || [[ -z "${VEX_NOTARY_TEAM_ID:-}" ]] \
    || [[ -z "${VEX_NOTARY_PASSWORD:-}" ]]; }; then
  fail "set VEX_NOTARY_PROFILE or the Apple ID, team ID, and app-specific password"
fi

export VEX_NATIVE_PRODUCTION=1
export VEX_NATIVE_REQUIRE_DEVELOPER_ID=1
export VEX_SPARKLE_PRODUCTION=1
export VEX_SPARKLE_REQUIRE_DEVELOPER_ID=1

bash "${ROOT_DIR}/scripts/build_native_macos_sparkle_release.sh"

export VEX_NATIVE_SKIP_APP_BUILD=1
pkg_path="$(bash "${ROOT_DIR}/scripts/build_native_macos_pkg.sh" | tail -n 1)"
[[ -f "${pkg_path}" ]] || fail "package build did not produce ${pkg_path}"

notary_args=()
if [[ -n "${VEX_NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "${VEX_NOTARY_PROFILE}")
else
  notary_args=(
    --apple-id "${VEX_NOTARY_APPLE_ID}"
    --team-id "${VEX_NOTARY_TEAM_ID}"
    --password "${VEX_NOTARY_PASSWORD}"
  )
fi
xcrun notarytool submit "${pkg_path}" "${notary_args[@]}" --wait
xcrun stapler staple "${pkg_path}"
xcrun stapler validate "${pkg_path}"

pkg_name="$(basename "${pkg_path}")"
pkg_sha="$(shasum -a 256 "${pkg_path}" | awk '{print $1}')"
printf '%s  %s\n' "${pkg_sha}" "${pkg_name}" >"${pkg_path}.sha256"
cp "${pkg_path}" "${ARCHIVES_DIR}/${pkg_name}"
cp "${pkg_path}.sha256" "${ARCHIVES_DIR}/${pkg_name}.sha256"

python3 - "${ARCHIVES_DIR}/release-manifest.json" "${pkg_name}" "${pkg_sha}" <<'PY'
import json
import sys
from pathlib import Path

path, package, package_sha = sys.argv[1:]
manifest_path = Path(path)
manifest = json.loads(manifest_path.read_text())
prefix = str(manifest["downloadURL"]).rsplit("/", 1)[0]
manifest.update({
    "package": package,
    "packageDownloadURL": f"{prefix}/{package}",
    "packageSHA256": package_sha,
    "packageSHA256Sidecar": f"{package}.sha256",
    "appleDeveloperSigned": True,
    "notarized": True,
    "gatekeeperReady": True,
    "distributionMode": "developer-id-notarized",
})
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
PY

VEX_NATIVE_APP_PATH="${ROOT_DIR}/macos-native/build/VEXNativeMac.app" \
  VEX_NATIVE_PKG_PATH="${pkg_path}" \
  VEX_SPARKLE_ARCHIVES_DIR="${ARCHIVES_DIR}" \
  bash "${ROOT_DIR}/scripts/native_macos_production_preflight.sh"

echo "Public app archive: ${ARCHIVES_DIR}/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "${ARCHIVES_DIR}/release-manifest.json")"
echo "Public installer: ${ARCHIVES_DIR}/${pkg_name}"
echo "Public manifest: ${ARCHIVES_DIR}/release-manifest.json"

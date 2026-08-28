#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${VEX_SELF_SIGNED_RELEASE_DIR:-${ROOT_DIR}/macos-native/build/self-signed-release}"
APP_PATH="${ROOT_DIR}/macos-native/build/VEXNativeMac.app"
DOWNLOAD_PREFIX="${VEX_SELF_SIGNED_DOWNLOAD_URL_PREFIX:-https://vexguard.app/downloads/native-macos}"

fail() {
  echo "self-signed release failed: $*" >&2
  exit 2
}

for name in \
  VEX_NATIVE_VERSION VEX_NATIVE_BUILD VEX_CODESIGN_IDENTITY VEX_CODESIGN_KEYCHAIN \
  VEX_SELF_SIGNED_APP_CERT_PATH VEX_SPARKLE_PUBLIC_ED_KEY VEX_SPARKLE_PRIVATE_ED_KEY_FILE; do
  [[ -n "${!name:-}" ]] || fail "${name} is required"
done
[[ "${VEX_CODESIGN_IDENTITY}" != Developer\ ID\ Application:* ]] \
  || fail "self-signed channel refuses Developer ID Application identity"
[[ -f "${VEX_CODESIGN_KEYCHAIN}" ]] || fail "signing keychain is missing"
[[ -f "${VEX_SELF_SIGNED_APP_CERT_PATH}" ]] || fail "application certificate is missing"
[[ -f "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}" ]] || fail "Sparkle private Ed25519 key is missing"
[[ "${DOWNLOAD_PREFIX}" == https://* ]] || fail "download URL prefix must use HTTPS"

certificate_sha256() {
  openssl x509 -in "$1" -outform der | shasum -a 256 | awk '{print $1}'
}

app_certificate_sha256="$(certificate_sha256 "${VEX_SELF_SIGNED_APP_CERT_PATH}")"

old_keychains=()
while IFS= read -r line; do
  keychain="$(printf '%s' "${line}" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"
  [[ -z "${keychain}" ]] || old_keychains+=("${keychain}")
done < <(security list-keychains -d user)

restore_keychains() {
  if (( ${#old_keychains[@]} > 0 )); then
    security list-keychains -d user -s "${old_keychains[@]}" >/dev/null
  fi
}
trap restore_keychains EXIT
security list-keychains -d user -s "${VEX_CODESIGN_KEYCHAIN}" "${old_keychains[@]}"

export VEX_CODESIGN_TIMESTAMP=none
export VEX_CODESIGN_ENTITLEMENTS="${ROOT_DIR}/macos-native/VEXSelfSigned.entitlements"
export VEX_NATIVE_DISTRIBUTION_MODE=self-signed-manual-approval
export VEX_NATIVE_PACKAGE_SUFFIX=-self-signed
export VEX_NOTARIZE=0

bash "${ROOT_DIR}/scripts/build_native_macos_app.sh"
export VEX_NATIVE_SKIP_APP_BUILD=1
# PackageKit rejects an outer PKG signed by an untrusted self-signed installer
# certificate before postinstall. Keep the payload certificate-pinned, but make
# the outer manual-approval PKG explicitly unsigned.
unset VEX_INSTALLER_SIGN_IDENTITY
unset VEX_INSTALLER_SIGN_KEYCHAIN
unset VEX_INSTALLER_SIGN_TIMESTAMP
pkg_path="$(bash "${ROOT_DIR}/scripts/build_native_macos_pkg.sh" | tail -n 1)"
[[ -f "${pkg_path}" ]] || fail "package build did not produce ${pkg_path}"

certificate_dir="$(mktemp -d /var/tmp/vex-self-signed-certificate.XXXXXX)"
codesign -d --extract-certificates="${certificate_dir}/certificate" "${APP_PATH}" >/dev/null 2>&1
actual_app_certificate_sha256="$(shasum -a 256 "${certificate_dir}/certificate0" | awk '{print $1}')"
/bin/rm -rf "${certificate_dir}"
[[ "${actual_app_certificate_sha256}" == "${app_certificate_sha256}" ]] \
  || fail "app certificate fingerprint mismatch"

pkg_signature_report="$(pkgutil --check-signature "${pkg_path}" 2>&1 || true)"
grep -q "Status: no signature" <<<"${pkg_signature_report}" \
  || fail "manual-approval PKG must be unsigned; PackageKit rejects untrusted self-signed installer certificates"

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
archive_name="VEXNativeMac-${VEX_NATIVE_VERSION}-${VEX_NATIVE_BUILD}-self-signed.zip"
archive_path="${RELEASE_DIR}/${archive_name}"
package_name="$(basename "${pkg_path}")"
package_release_path="${RELEASE_DIR}/${package_name}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${archive_path}"
cp "${pkg_path}" "${package_release_path}"

write_sha256() {
  local path="$1"
  local hash
  hash="$(shasum -a 256 "${path}" | awk '{print $1}')"
  printf '%s  %s\n' "${hash}" "$(basename "${path}")" >"${path}.sha256"
  printf '%s' "${hash}"
}
archive_sha256="$(write_sha256 "${archive_path}")"
package_sha256="$(write_sha256 "${package_release_path}")"
appcast_tool="${ROOT_DIR}/macos-native/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_update_tool="${ROOT_DIR}/macos-native/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "${appcast_tool}" ]] || fail "Sparkle generate_appcast tool is missing"
[[ -x "${sign_update_tool}" ]] || fail "Sparkle sign_update tool is missing"
"${appcast_tool}" \
  --ed-key-file "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}" \
  --download-url-prefix "${DOWNLOAD_PREFIX%/}/" \
  --maximum-deltas 0 \
  --maximum-versions 1 \
  -o "${RELEASE_DIR}/appcast.xml" \
  "${RELEASE_DIR}"
archive_signature="$(python3 - "${RELEASE_DIR}/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
enclosure = ET.parse(sys.argv[1]).getroot().find("./channel/item/enclosure")
if enclosure is None:
    raise SystemExit("appcast latest item has no enclosure")
signature = enclosure.attrib.get(f"{{{namespace}}}edSignature", "")
if not signature:
    raise SystemExit("appcast latest enclosure has no Ed25519 signature")
print(signature)
PY
)"
"${sign_update_tool}" --verify --ed-key-file "${VEX_SPARKLE_PRIVATE_ED_KEY_FILE}" \
  "${archive_path}" "${archive_signature}"
appcast_sha256="$(write_sha256 "${RELEASE_DIR}/appcast.xml")"

python3 - "${RELEASE_DIR}/release-manifest.json" <<PY
import json
from pathlib import Path

manifest = {
    "product": "VEX Native macOS",
    "bundleIdentifier": "app.vex.vpn.native",
    "version": "${VEX_NATIVE_VERSION}",
    "build": "${VEX_NATIVE_BUILD}",
    "channel": "self-signed",
    "distributionMode": "self-signed-manual-approval",
    "archive": "${archive_name}",
    "downloadURL": "${DOWNLOAD_PREFIX%/}/${archive_name}",
    "archiveSHA256": "${archive_sha256}",
    "archiveSHA256Sidecar": "${archive_name}.sha256",
    "package": "${package_name}",
    "packageDownloadURL": "${DOWNLOAD_PREFIX%/}/${package_name}",
    "packageSHA256": "${package_sha256}",
    "packageSHA256Sidecar": "${package_name}.sha256",
    "selfSigned": True,
    "signatureVerified": True,
    "signingCertificateSHA256": "${app_certificate_sha256}",
    "packageSigned": False,
    "packageTrust": "unsigned-manual-approval",
    "automaticUpdates": True,
    "libraryValidationDisabled": True,
    "feedURL": "${DOWNLOAD_PREFIX%/}/appcast.xml",
    "appcast": "appcast.xml",
    "appcastSHA256": "${appcast_sha256}",
    "appcastSHA256Sidecar": "appcast.xml.sha256",
    "sparklePublicEDKey": "${VEX_SPARKLE_PUBLIC_ED_KEY}",
    "updateSignatureScheme": "sparkle-ed25519",
    "appleDeveloperSigned": False,
    "notarized": False,
    "gatekeeperReady": False,
    "requiresManualApproval": True,
    "manualApprovalPath": "System Settings > Privacy & Security > Open Anyway",
    "securityProtectionsDisabled": False,
    "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
}
Path("${RELEASE_DIR}/release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

VEX_NATIVE_APP_PATH="${APP_PATH}" \
  VEX_NATIVE_PKG_PATH="${package_release_path}" \
  VEX_NATIVE_PRODUCTION=0 \
  VEX_NATIVE_REQUIRE_DEVELOPER_ID=0 \
  VEX_NATIVE_EXPECTED_APP_CERT_SHA256="${app_certificate_sha256}" \
  VEX_SPARKLE_ARCHIVES_DIR="${RELEASE_DIR}" \
  bash "${ROOT_DIR}/scripts/native_macos_production_preflight.sh"

VEX_SPARKLE_ARCHIVES_DIR="${RELEASE_DIR}" \
  VEX_NATIVE_DEPLOY_BUNDLE_DIR="${VEX_SELF_SIGNED_DEPLOY_BUNDLE_DIR:-${ROOT_DIR}/dist/native-macos/self-signed-deploy}" \
  bash "${ROOT_DIR}/scripts/prepare_native_macos_deploy_bundle.sh"

echo "Self-signed installer: ${package_release_path}"
echo "Self-signed manifest: ${RELEASE_DIR}/release-manifest.json"
echo "This channel is not notarized or Gatekeeper-ready and requires explicit macOS approval."

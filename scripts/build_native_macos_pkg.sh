#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_native_macos_app.sh"
PACKAGE_DIR="${ROOT_DIR}/macos-native"
BUILD_DIR="${PACKAGE_DIR}/build"
APP_NAME="VEXNativeMac"
INSTALL_APP_BUNDLE_NAME="VEX Native.app"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
PKG_ROOT="${BUILD_DIR}/pkg-root"
PKG_SCRIPTS="${BUILD_DIR}/pkg-scripts"
PKG_OUTPUT_DIR="${BUILD_DIR}/pkg"
APP_VERSION="${VEX_NATIVE_VERSION:-0.1.0}"
APP_BUILD="${VEX_NATIVE_BUILD:-1}"
PKG_NAME="VEXNativeMac-${APP_VERSION}-${APP_BUILD}.pkg"
PKG_PATH="${PKG_OUTPUT_DIR}/${PKG_NAME}"
PKG_SIGN_IDENTITY="${VEX_INSTALLER_SIGN_IDENTITY:-}"
PKG_SIGN_KEYCHAIN="${VEX_INSTALLER_SIGN_KEYCHAIN:-}"
PKG_SIGN_TIMESTAMP="${VEX_INSTALLER_SIGN_TIMESTAMP:-trusted}"
DISTRIBUTION_MODE="${VEX_NATIVE_DISTRIBUTION_MODE:-internal}"
PACKAGE_SUFFIX="${VEX_NATIVE_PACKAGE_SUFFIX:-}"
SKIP_APP_BUILD="${VEX_NATIVE_SKIP_APP_BUILD:-0}"

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
  APP_VERSION="${VEX_NATIVE_VERSION:-${APP_VERSION}}"
  APP_BUILD="${VEX_NATIVE_BUILD:-${APP_BUILD}}"
  PKG_SIGN_IDENTITY="${VEX_INSTALLER_SIGN_IDENTITY:-${PKG_SIGN_IDENTITY}}"
  PKG_SIGN_KEYCHAIN="${VEX_INSTALLER_SIGN_KEYCHAIN:-${PKG_SIGN_KEYCHAIN}}"
  PKG_SIGN_TIMESTAMP="${VEX_INSTALLER_SIGN_TIMESTAMP:-${PKG_SIGN_TIMESTAMP}}"
  DISTRIBUTION_MODE="${VEX_NATIVE_DISTRIBUTION_MODE:-${DISTRIBUTION_MODE}}"
  PACKAGE_SUFFIX="${VEX_NATIVE_PACKAGE_SUFFIX:-${PACKAGE_SUFFIX}}"
  PKG_NAME="VEXNativeMac-${APP_VERSION}-${APP_BUILD}${PACKAGE_SUFFIX}.pkg"
  PKG_PATH="${PKG_OUTPUT_DIR}/${PKG_NAME}"
fi

if [[ ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "VEX_NATIVE_BUILD must be numeric; got '${APP_BUILD}'" >&2
  exit 1
fi
if [[ ! "${PACKAGE_SUFFIX}" =~ ^[A-Za-z0-9._-]*$ ]]; then
  echo "VEX_NATIVE_PACKAGE_SUFFIX contains unsupported characters" >&2
  exit 1
fi
PKG_NAME="VEXNativeMac-${APP_VERSION}-${APP_BUILD}${PACKAGE_SUFFIX}.pkg"
PKG_PATH="${PKG_OUTPUT_DIR}/${PKG_NAME}"

if [[ "${SKIP_APP_BUILD}" == "1" ]]; then
  if [[ ! -d "${APP_DIR}" ]]; then
    echo "VEX_NATIVE_SKIP_APP_BUILD=1 requires an existing app bundle: ${APP_DIR}" >&2
    exit 1
  fi
else
  bash "${BUILD_SCRIPT}"
fi

rm -rf "${PKG_ROOT}" "${PKG_SCRIPTS}" "${PKG_OUTPUT_DIR}"
mkdir -p "${PKG_ROOT}/Applications" "${PKG_SCRIPTS}" "${PKG_OUTPUT_DIR}"

ditto "${APP_DIR}" "${PKG_ROOT}/Applications/${INSTALL_APP_BUNDLE_NAME}"

APP_TEAM_ID="$(
  /usr/bin/codesign -d --verbose=4 "${APP_DIR}" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
)"
APP_CERTIFICATE_DIR="$(/usr/bin/mktemp -d /var/tmp/vex-package-certificate.XXXXXX)"
trap '/bin/rm -rf "$APP_CERTIFICATE_DIR"' EXIT
/usr/bin/codesign -d --extract-certificates="${APP_CERTIFICATE_DIR}/certificate" "${APP_DIR}" >/dev/null 2>&1
if [[ ! -f "${APP_CERTIFICATE_DIR}/certificate0" ]]; then
  echo "App signing certificate could not be extracted." >&2
  exit 1
fi
APP_CERTIFICATE_SHA1="$(/usr/bin/shasum "${APP_CERTIFICATE_DIR}/certificate0" | /usr/bin/awk '{print $1}')"
APP_CERTIFICATE_SHA256="$(/usr/bin/shasum -a 256 "${APP_CERTIFICATE_DIR}/certificate0" | /usr/bin/awk '{print $1}')"

if [[ -n "${APP_TEAM_ID}" && "${APP_TEAM_ID}" != "not set" ]]; then
  APP_REQUIREMENT="anchor apple generic and identifier \"app.vex.vpn.native\" and certificate leaf[subject.OU] = \"${APP_TEAM_ID}\""
  EXPECTED_TEAM_ID="${APP_TEAM_ID}"
  EXPECTED_CERTIFICATE_SHA256=""
elif [[ "${DISTRIBUTION_MODE}" == "self-signed-manual-approval" ]]; then
  APP_REQUIREMENT="identifier \"app.vex.vpn.native\" and certificate leaf = H\"${APP_CERTIFICATE_SHA1}\""
  EXPECTED_TEAM_ID=""
  EXPECTED_CERTIFICATE_SHA256="${APP_CERTIFICATE_SHA256}"
else
  echo "Developer ID TeamIdentifier is required outside the self-signed channel." >&2
  exit 1
fi

cat > "${PKG_SCRIPTS}/postinstall" <<'POSTINSTALL'
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/VEX Native.app"
verified_root="$(/usr/bin/mktemp -d /var/tmp/vex-install-app.XXXXXX)"
trap '/bin/rm -rf "$verified_root"' EXIT
/usr/bin/ditto "${APP_PATH}" "$verified_root/VEX Native.app"
verified_app="$verified_root/VEX Native.app"
/usr/bin/codesign --verify --deep --strict \
  -R='__VEX_APP_REQUIREMENT__' \
  "$verified_app"
resource_dir="${verified_app}/Contents/Resources/resources"
installer="${resource_dir}/install-vex-vpn-helper.sh"

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [[ -z "${console_user}" || "${console_user}" == "root" ]]; then
  console_user="$(logname 2>/dev/null || true)"
fi

if [[ -n "${console_user}" && "${console_user}" != "root" ]]; then
  console_home="$(dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
fi

if [[ -z "${console_home:-}" ]]; then
  console_home="/var/root"
  console_user="root"
fi

config_path="${console_home}/.vex/vex.conf"

VEX_EXPECTED_TEAM_ID="__VEX_TEAM_ID__" VEX_EXPECTED_CERT_SHA256="__VEX_CERT_SHA256__" /bin/bash "${installer}" "${resource_dir}" "${config_path}" "${console_user}" "${verified_app}"
POSTINSTALL

python3 - "${PKG_SCRIPTS}/postinstall" "${APP_REQUIREMENT}" "${EXPECTED_TEAM_ID}" "${EXPECTED_CERTIFICATE_SHA256}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("__VEX_APP_REQUIREMENT__", sys.argv[2])
text = text.replace("__VEX_TEAM_ID__", sys.argv[3])
text = text.replace("__VEX_CERT_SHA256__", sys.argv[4])
path.write_text(text)
PY

chmod 755 "${PKG_SCRIPTS}/postinstall"

pkgbuild \
  --root "${PKG_ROOT}" \
  --identifier "app.vex.vpn.native" \
  --version "${APP_BUILD}" \
  --install-location "/" \
  --scripts "${PKG_SCRIPTS}" \
  "${PKG_PATH}"

if [[ -n "${PKG_SIGN_IDENTITY}" ]]; then
  SIGNED_PATH="${PKG_PATH%.pkg}-signed.pkg"
  productsign_args=(--sign "${PKG_SIGN_IDENTITY}")
  if [[ -n "${PKG_SIGN_KEYCHAIN}" ]]; then
    productsign_args+=(--keychain "${PKG_SIGN_KEYCHAIN}")
  fi
  if [[ "${PKG_SIGN_TIMESTAMP}" == "none" ]]; then
    productsign_args+=(--timestamp=none)
  fi
  productsign "${productsign_args[@]}" "${PKG_PATH}" "${SIGNED_PATH}"
  mv "${SIGNED_PATH}" "${PKG_PATH}"
  pkgutil --check-signature "${PKG_PATH}" >/dev/null
fi

echo "${PKG_PATH}"

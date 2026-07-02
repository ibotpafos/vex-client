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

if [[ -f "${ROOT_DIR}/.env.sparkle.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env.sparkle.local"
  set +a
  APP_VERSION="${VEX_NATIVE_VERSION:-${APP_VERSION}}"
  APP_BUILD="${VEX_NATIVE_BUILD:-${APP_BUILD}}"
  PKG_SIGN_IDENTITY="${VEX_INSTALLER_SIGN_IDENTITY:-${PKG_SIGN_IDENTITY}}"
  PKG_NAME="VEXNativeMac-${APP_VERSION}-${APP_BUILD}.pkg"
  PKG_PATH="${PKG_OUTPUT_DIR}/${PKG_NAME}"
fi

if [[ ! "${APP_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "VEX_NATIVE_BUILD must be numeric; got '${APP_BUILD}'" >&2
  exit 1
fi

bash "${BUILD_SCRIPT}"

rm -rf "${PKG_ROOT}" "${PKG_SCRIPTS}" "${PKG_OUTPUT_DIR}"
mkdir -p "${PKG_ROOT}/Applications" "${PKG_SCRIPTS}" "${PKG_OUTPUT_DIR}"

ditto "${APP_DIR}" "${PKG_ROOT}/Applications/${INSTALL_APP_BUNDLE_NAME}"

cat > "${PKG_SCRIPTS}/postinstall" <<'POSTINSTALL'
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/VEX Native.app"
RESOURCE_DIR="${APP_PATH}/Contents/Resources/resources"
INSTALLER="${RESOURCE_DIR}/install-vex-vpn-helper.sh"

if [[ ! -x "${INSTALLER}" ]]; then
  echo "Missing helper installer at ${INSTALLER}" >&2
  exit 1
fi

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
mkdir -p "$(dirname "${config_path}")"

/bin/bash "${INSTALLER}" "${RESOURCE_DIR}" "${config_path}" "${console_user}"
POSTINSTALL

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
  productsign --sign "${PKG_SIGN_IDENTITY}" "${PKG_PATH}" "${SIGNED_PATH}"
  mv "${SIGNED_PATH}" "${PKG_PATH}"
  pkgutil --check-signature "${PKG_PATH}" >/dev/null
fi

echo "${PKG_PATH}"

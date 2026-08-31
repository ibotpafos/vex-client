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

maybe_notarize_pkg() {
  if [[ "${VEX_NOTARIZE:-0}" != "1" ]]; then
    return
  fi
  if [[ -z "${PKG_SIGN_IDENTITY}" ]]; then
    echo "VEX_NOTARIZE=1 requires VEX_INSTALLER_SIGN_IDENTITY." >&2
    exit 2
  fi

  local profile_args=()
  if [[ -n "${VEX_NOTARY_PROFILE:-}" ]]; then
    profile_args=(--keychain-profile "${VEX_NOTARY_PROFILE}")
    if [[ -n "${VEX_NOTARY_KEYCHAIN:-}" ]]; then
      profile_args+=(--keychain "${VEX_NOTARY_KEYCHAIN}")
    fi
  else
    if [[ -z "${VEX_NOTARY_APPLE_ID:-}" || -z "${VEX_NOTARY_TEAM_ID:-}" || -z "${VEX_NOTARY_PASSWORD:-}" ]]; then
      echo "Set VEX_NOTARY_PROFILE or VEX_NOTARY_APPLE_ID/VEX_NOTARY_TEAM_ID/VEX_NOTARY_PASSWORD for package notarization." >&2
      exit 2
    fi
    profile_args=(--apple-id "${VEX_NOTARY_APPLE_ID}" --team-id "${VEX_NOTARY_TEAM_ID}" --password "${VEX_NOTARY_PASSWORD}")
  fi

  xcrun notarytool submit "${PKG_PATH}" "${profile_args[@]}" --wait
  xcrun stapler staple "${PKG_PATH}"
  xcrun stapler validate "${PKG_PATH}"
}

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

APP_TEAM_ID="$(
  /usr/bin/codesign -d --verbose=4 "${APP_DIR}" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
)"
if [[ -z "${APP_TEAM_ID}" || "${APP_TEAM_ID}" == "not set" ]]; then
  echo "Developer ID TeamIdentifier is required to package the privileged helper." >&2
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
  -R='anchor apple generic and identifier "app.vex.vpn.native" and certificate leaf[subject.OU] = "__VEX_TEAM_ID__"' \
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
mkdir -p "$(dirname "${config_path}")"

VEX_EXPECTED_TEAM_ID="__VEX_TEAM_ID__" /bin/bash "${installer}" "${resource_dir}" "${config_path}" "${console_user}" "${verified_app}"
POSTINSTALL

/usr/bin/sed -i '' "s/__VEX_TEAM_ID__/${APP_TEAM_ID}/g" "${PKG_SCRIPTS}/postinstall"

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

maybe_notarize_pkg

echo "${PKG_PATH}"

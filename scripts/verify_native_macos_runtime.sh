#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
SOURCE_HELPER="${SOURCE_HELPER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src-tauri/resources/vex-helper}"
ROOT_HELPER="${ROOT_HELPER:-/Library/Application Support/VEX VPN/helper/vex-helper}"
ROOT_HELPER_DIR="$(/usr/bin/dirname "${ROOT_HELPER}")"
HELPER_PLIST="${HELPER_PLIST:-/Library/LaunchDaemons/app.vex.vpn.helper.plist}"
HELPER_SOCKET="${HELPER_SOCKET:-/var/run/vex-helper.sock}"
STRICT="${STRICT:-0}"

failures=0

record_failure() {
  local message="$1"
  echo "fail=${message}"
  failures=$((failures + 1))
}

sha256_or_empty() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    /usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}'
  fi
}

helper_version_from_bundle() {
  local installer="$1"
  local resource_dir
  resource_dir="$(/usr/bin/dirname "${installer}")"
  if [[ -f "${resource_dir}/helper-version" ]]; then
    /usr/bin/tr -d '[:space:]' <"${resource_dir}/helper-version"
  elif [[ -f "${installer}" ]]; then
    /usr/bin/sed -n 's/^helper_version="\([^"]*\)".*/\1/p' "${installer}" | /usr/bin/head -n 1
  fi
}

file_contents_or_empty() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    /bin/cat "${path}"
  fi
}

route_interface() {
  /sbin/route -n get 8.8.8.8 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*interface: //p' | /usr/bin/head -n 1
}

echo "app_path=${APP_PATH}"
if [[ ! -d "${APP_PATH}" ]]; then
  record_failure "installed app missing"
else
  app_version="$(/usr/bin/defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  app_build="$(/usr/bin/defaults read "${APP_PATH}/Contents/Info" CFBundleVersion 2>/dev/null || true)"
  echo "app_version=${app_version}"
  echo "app_build=${app_build}"
  if /usr/bin/codesign --verify --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
    echo "app_codesign=ok"
  else
    echo "app_codesign=failed"
    record_failure "installed app codesign failed"
  fi
fi

app_helper="${APP_PATH}/Contents/Resources/resources/vex-helper"
app_helper_installer="${APP_PATH}/Contents/Resources/resources/install-vex-vpn-helper.sh"
app_helper_sha="$(sha256_or_empty "${app_helper}")"
source_helper_sha="$(sha256_or_empty "${SOURCE_HELPER}")"
root_helper_sha="$(sha256_or_empty "${ROOT_HELPER}")"
app_helper_version="$(helper_version_from_bundle "${app_helper_installer}")"
root_helper_version="$(file_contents_or_empty "${ROOT_HELPER_DIR}/version" | /usr/bin/tr -d '[:space:]')"
helper_plist_run_at_load=""
helper_plist_keep_alive=""
if [[ -f "${HELPER_PLIST}" ]]; then
  helper_plist_run_at_load="$(/usr/bin/plutil -extract RunAtLoad raw -o - "${HELPER_PLIST}" 2>/dev/null || true)"
  helper_plist_keep_alive="$(/usr/bin/plutil -extract KeepAlive raw -o - "${HELPER_PLIST}" 2>/dev/null || true)"
fi

echo "app_helper_sha=${app_helper_sha}"
echo "source_helper_sha=${source_helper_sha}"
echo "root_helper_sha=${root_helper_sha}"
echo "app_helper_version=${app_helper_version}"
echo "root_helper_version=${root_helper_version}"
echo "helper_plist_run_at_load=${helper_plist_run_at_load}"
echo "helper_plist_keep_alive=${helper_plist_keep_alive}"

if [[ -z "${app_helper_sha}" ]]; then
  record_failure "bundled helper missing"
fi
if [[ -z "${source_helper_sha}" ]]; then
  record_failure "source helper missing"
fi
if [[ -z "${root_helper_sha}" ]]; then
  record_failure "root helper missing"
fi
if [[ -n "${app_helper_sha}" && -n "${source_helper_sha}" && "${app_helper_sha}" != "${source_helper_sha}" ]]; then
  record_failure "bundled helper does not match source helper"
fi
if [[ -n "${app_helper_sha}" && -n "${root_helper_sha}" && "${app_helper_sha}" != "${root_helper_sha}" ]]; then
  record_failure "root helper does not match bundled helper"
fi
if [[ -n "${app_helper_version}" && "${app_helper_version}" != "${root_helper_version}" ]]; then
  record_failure "root helper version does not match bundled helper version"
fi
if [[ "${helper_plist_run_at_load}" != "true" || "${helper_plist_keep_alive}" != "true" ]]; then
  record_failure "helper LaunchDaemon is not configured to start and stay alive"
fi
if [[ -n "${app_helper_sha}" && -n "${root_helper_sha}" && "${app_helper_sha}" != "${root_helper_sha}" ]] \
  || [[ "${helper_plist_run_at_load}" != "true" || "${helper_plist_keep_alive}" != "true" ]]; then
  echo "helper_install_action=APP_PATH=${APP_PATH} bash scripts/install_native_macos_helper_from_app.sh"
fi

if [[ -S "${HELPER_SOCKET}" ]]; then
  if helper_status="$(/usr/bin/printf 'status\n' | /usr/bin/nc -U "${HELPER_SOCKET}" 2>/dev/null || true)"; then
    helper_status="${helper_status//$'\n'/ }"
    echo "helper_socket=responds"
    echo "helper_status=${helper_status}"
  else
    echo "helper_socket=unreachable"
  fi
else
  echo "helper_socket=missing"
fi

echo "route_iface=$(route_interface)"
echo "active_network_vpns_begin"
/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep '(Connected)' || true
echo "active_network_vpns_end"

if [[ "${STRICT}" == "1" && "${failures}" -gt 0 ]]; then
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
CONFIG_PATH="${CONFIG_PATH:-${HOME}/.vex/vex.conf}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/vex-vpn-install.log}"
RUN_VERIFY="${RUN_VERIFY:-1}"

fail() {
  echo "helper install failed: $*" >&2
  exit 1
}

resource_dir="${APP_PATH}/Contents/Resources/resources"
installer="${resource_dir}/install-vex-vpn-helper.sh"

[[ -d "${APP_PATH}" ]] || fail "installed app not found: ${APP_PATH}"
[[ -x "${installer}" ]] || fail "helper installer not executable: ${installer}"
for resource in awg amneziawg-go vex-helper; do
  [[ -x "${resource_dir}/${resource}" ]] || fail "missing executable helper resource: ${resource}"
done

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

shell_command="/bin/bash $(shell_quote "${installer}") $(shell_quote "${resource_dir}") $(shell_quote "${CONFIG_PATH}") $(shell_quote "${USER}") > $(shell_quote "${INSTALL_LOG}") 2>&1"
apple_script="do shell script \"${shell_command//\\/\\\\}\" with administrator privileges"

/usr/bin/osascript -e "${apple_script}"

if [[ "${RUN_VERIFY}" == "1" ]]; then
  STRICT=1 APP_PATH="${APP_PATH}" bash "${ROOT_DIR}/scripts/verify_native_macos_runtime.sh"
fi

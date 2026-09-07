#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
CONFIG_PATH="${CONFIG_PATH:-${HOME}/.vex/vex.conf}"
RUN_VERIFY="${RUN_VERIFY:-1}"


fail() {
  echo "helper install failed: $*" >&2
  exit 1
}

resource_dir="${APP_PATH}/Contents/Resources/resources"
installer="${resource_dir}/install-vex-vpn-helper.sh"

[[ -d "${APP_PATH}" ]] || fail "installed app not found: ${APP_PATH}"
[[ -x "${installer}" ]] || fail "helper installer not executable: ${installer}"
for resource in awg amneziawg-go awg-quick.sh vex-helper; do
  [[ -x "${resource_dir}/${resource}" ]] || fail "missing executable helper resource: ${resource}"
done
[[ -r "${resource_dir}/helper-version" ]] || fail "missing readable helper resource: helper-version"
# Fixed approved Apple team or exact local leaf certificate; never environment trust.
app_requirement='identifier "app.vex.vpn.native" and (certificate leaf = H"c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e" or (anchor apple generic and certificate leaf[subject.OU] = "3JLW9XNU53"))'
/usr/bin/codesign --verify --deep --strict -R="${app_requirement}" "${APP_PATH}" || fail "app bundle signature or pinned identity verification failed"

shell_quote() {
  # Bash quoting also preserves apostrophes and newlines on macOS Bash 3.2.
  printf '%q' "$1"
}

shell_command="set -euo pipefail; verified_root=\$(/usr/bin/mktemp -d /var/tmp/vex-install-app.XXXXXX); trap '/bin/rm -rf \"\$verified_root\"' EXIT; /usr/bin/ditto $(shell_quote "${APP_PATH}") \"\$verified_root/VEX Native.app\"; verified_app=\"\$verified_root/VEX Native.app\"; /usr/bin/codesign --verify --deep --strict -R=$(shell_quote "${app_requirement}") \"\$verified_app\"; verified_resources=\"\$verified_app/Contents/Resources/resources\"; /bin/bash \"\$verified_resources/install-vex-vpn-helper.sh\" \"\$verified_resources\" $(shell_quote "${CONFIG_PATH}") $(shell_quote "${USER}") \"\$verified_app\""
escaped_shell_command="${shell_command//\\/\\\\}"
escaped_shell_command="${escaped_shell_command//\"/\\\"}"
apple_script="do shell script \"${escaped_shell_command}\" with administrator privileges"

/usr/bin/osascript -e "${apple_script}"

if [[ "${RUN_VERIFY}" == "1" ]]; then
  STRICT=1 APP_PATH="${APP_PATH}" bash "${ROOT_DIR}/scripts/verify_native_macos_runtime.sh"
fi

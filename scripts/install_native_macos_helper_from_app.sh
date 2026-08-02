#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
CONFIG_PATH="${CONFIG_PATH:-${HOME}/.vex/vex.conf}"
RUN_VERIFY="${RUN_VERIFY:-1}"
PINNED_VEX_TEAM_ID="3JLW9XNU53"

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
/usr/bin/codesign --verify --deep --strict "${APP_PATH}" || fail "app bundle signature verification failed"
team_id="$(
  /usr/bin/codesign -d --verbose=4 "${APP_PATH}" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
)"
[[ -n "${team_id}" && "${team_id}" != "not set" ]] || fail "signed app TeamIdentifier is missing"
[[ "${team_id}" == "${PINNED_VEX_TEAM_ID}" ]] || fail "app TeamIdentifier does not match pinned VEX identity"
team_id="${PINNED_VEX_TEAM_ID}"
app_requirement="anchor apple generic and identifier \"app.vex.vpn.native\" and certificate leaf[subject.OU] = \"${team_id}\""

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

shell_command="set -euo pipefail; verified_root=\$(/usr/bin/mktemp -d /var/tmp/vex-install-app.XXXXXX); trap '/bin/rm -rf \"\$verified_root\"' EXIT; /usr/bin/ditto $(shell_quote "${APP_PATH}") \"\$verified_root/VEX Native.app\"; verified_app=\"\$verified_root/VEX Native.app\"; /usr/bin/codesign --verify --deep --strict -R=$(shell_quote "${app_requirement}") \"\$verified_app\"; verified_resources=\"\$verified_app/Contents/Resources/resources\"; VEX_EXPECTED_TEAM_ID=$(shell_quote "${team_id}") /bin/bash \"\$verified_resources/install-vex-vpn-helper.sh\" \"\$verified_resources\" $(shell_quote "${CONFIG_PATH}") $(shell_quote "${USER}") \"\$verified_app\""
escaped_shell_command="${shell_command//\\/\\\\}"
escaped_shell_command="${escaped_shell_command//\"/\\\"}"
apple_script="do shell script \"${escaped_shell_command}\" with administrator privileges"

/usr/bin/osascript -e "${apple_script}"

if [[ "${RUN_VERIFY}" == "1" ]]; then
  STRICT=1 APP_PATH="${APP_PATH}" bash "${ROOT_DIR}/scripts/verify_native_macos_runtime.sh"
fi

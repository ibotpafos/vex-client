#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/VEXNativeMac"
HELPER_PATH="${HELPER_PATH:-/Library/PrivilegedHelperTools/app.vex.vpn.helper}"
HELPER_PLIST="${HELPER_PLIST:-/Library/LaunchDaemons/app.vex.vpn.helper.plist}"
HELPER_LABEL="${HELPER_LABEL:-app.vex.vpn.helper}"
HELPER_SOCKET="${HELPER_SOCKET:-/var/run/vex-helper.sock}"

fail() {
  echo "helper_integration=failed"
  echo "fail=$*"
  exit 1
}

[[ -x "$APP_EXECUTABLE" ]] || fail "installed app executable is missing"
[[ -x "$HELPER_PATH" ]] || fail "privileged helper binary is missing"
[[ -f "$HELPER_PLIST" ]] || fail "LaunchDaemon plist is missing"
[[ -S "$HELPER_SOCKET" ]] || fail "helper socket is missing"

plist_label="$(/usr/bin/plutil -extract Label raw -o - "$HELPER_PLIST" 2>/dev/null || true)"
plist_program="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$HELPER_PLIST" 2>/dev/null || true)"
[[ "$plist_label" == "$HELPER_LABEL" ]] || fail "LaunchDaemon label is $plist_label"
[[ "$plist_program" == "$HELPER_PATH" ]] || fail "LaunchDaemon program is $plist_program"
/bin/launchctl print "system/$HELPER_LABEL" >/dev/null 2>&1 \
  || fail "system/$HELPER_LABEL is not loaded"

install_state="$("$APP_EXECUTABLE" --helper-install-state-probe 2>&1)" \
  || fail "app install-state probe rejected the installed helper: $install_state"
echo "$install_state"
grep -qx 'helper_files_current=true' <<<"$install_state" \
  || fail "app does not consider helper files current"
grep -qx 'helper_socket_connectable=true' <<<"$install_state" \
  || fail "app cannot connect to helper socket"
grep -qx 'helper_install_required=false' <<<"$install_state" \
  || fail "app still exposes helper install-required state"
grep -qx 'user_visible_message=<none>' <<<"$install_state" \
  || fail "app still exposes a helper installation error"

status="$("$APP_EXECUTABLE" --helper-status-probe 2>&1)" \
  || fail "signed app peer failed helper authentication: $status"
[[ "$status" == state=* && "$status" == *"operation_in_progress="* ]] \
  || fail "authenticated status response has an invalid frame"

echo "helper_launchd_label=$plist_label"
echo "helper_launchd_program=$plist_program"
echo "helper_launchd_service=loaded"
echo "helper_socket=responds_authenticated"
echo "helper_install_required=false"
echo "helper_integration=ok"

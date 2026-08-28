#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${APP_PATH:-/Applications/VEX Native.app}"
BUNDLE_ID="${BUNDLE_ID:-app.vex.vpn.native}"
PROCESS_NAME="${PROCESS_NAME:-VEXNativeMac}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-45}"
REQUIRE_SPARKLE_AUTOMATIC="${REQUIRE_SPARKLE_AUTOMATIC:-1}"
KEEP_RUNNING="${KEEP_RUNNING:-1}"
CRASH_DIR="${CRASH_DIR:-${HOME}/Library/Logs/DiagnosticReports}"

fail() {
  echo "launch_smoke=failed"
  echo "failure=$1"
  exit 1
}

matching_pids() {
  /usr/bin/pgrep -x "${PROCESS_NAME}" 2>/dev/null || true
}

new_crashes_since() {
  local sentinel="$1"
  /usr/bin/find "${CRASH_DIR}" -maxdepth 1 -type f \
    -name "${PROCESS_NAME}-*.ips" -newer "${sentinel}" -print 2>/dev/null \
    | /usr/bin/sort
}

[[ -d "${APP_PATH}" ]] || fail "installed app missing at ${APP_PATH}"

# The smoke must observe the first process. A surviving auto-relaunch must not
# hide an initial crash, which is exactly how build 120 produced a false pass.
if [[ -n "$(matching_pids)" ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  for _ in {1..100}; do
    [[ -z "$(matching_pids)" ]] && break
    /bin/sleep 0.1
  done
fi
[[ -z "$(matching_pids)" ]] || fail "existing ${PROCESS_NAME} did not terminate cleanly"

launch_sentinel="$(/usr/bin/mktemp /tmp/vex-native-launch-smoke.XXXXXX)"
trap '/bin/rm -f "${launch_sentinel}"' EXIT
started_epoch="$(/bin/date +%s)"
/usr/bin/open -a "${APP_PATH}"

initial_pid=""
for _ in {1..100}; do
  initial_pid="$(matching_pids | /usr/bin/head -n 1)"
  [[ -n "${initial_pid}" ]] && break
  /bin/sleep 0.1
done
[[ -n "${initial_pid}" ]] || fail "application process did not appear"

for ((second = 1; second <= OBSERVE_SECONDS; second++)); do
  current_pids="$(matching_pids)"
  [[ "${current_pids}" == "${initial_pid}" ]] \
    || fail "initial pid ${initial_pid} exited or another instance appeared (current: ${current_pids:-none})"
  /bin/sleep 1
done

# CrashReporter writes asynchronously. Give it time to publish a report before
# evaluating the launch window.
/bin/sleep 5
new_crashes="$(new_crashes_since "${launch_sentinel}")"
[[ -z "${new_crashes}" ]] || fail "new crash report after launch: ${new_crashes//$'\n'/, }"

vmmap_output="$(/usr/bin/mktemp /tmp/vex-native-vmmap.XXXXXX)"
trap '/bin/rm -f "${launch_sentinel}" "${vmmap_output}"' EXIT
/usr/bin/vmmap "${initial_pid}" >"${vmmap_output}" 2>/dev/null || true
if ! /usr/bin/grep -q '/Sparkle.framework/' "${vmmap_output}"; then
  fail "Sparkle.framework is not mapped in the launched process"
fi

sparkle_started_epoch="$(/usr/bin/defaults read "${BUNDLE_ID}" vex.sparkle.lastAutomaticStartup 2>/dev/null || true)"
if [[ "${REQUIRE_SPARKLE_AUTOMATIC}" == "1" ]]; then
  if [[ -z "${sparkle_started_epoch}" ]] \
    || ! /usr/bin/awk -v observed="${sparkle_started_epoch}" -v launch="${started_epoch}" 'BEGIN { exit !(observed >= launch) }'; then
    fail "automatic Sparkle startup was not observed for this launch"
  fi
fi

echo "launch_smoke=ok"
echo "app_path=${APP_PATH}"
echo "pid=${initial_pid}"
echo "observed_seconds=${OBSERVE_SECONDS}"
echo "new_crash_reports=0"
echo "sparkle_framework=mapped"
echo "sparkle_automatic_start=$([[ -n "${sparkle_started_epoch}" ]] && echo observed || echo not-required)"

if [[ "${KEEP_RUNNING}" != "1" ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit"
  for _ in {1..100}; do
    [[ -z "$(matching_pids)" ]] && break
    /bin/sleep 0.1
  done
  [[ -z "$(matching_pids)" ]] || fail "application did not terminate cleanly after smoke"
  /bin/sleep 3
  new_crashes="$(new_crashes_since "${launch_sentinel}")"
  [[ -z "${new_crashes}" ]] || fail "new crash report during graceful termination: ${new_crashes//$'\n'/, }"
  echo "graceful_quit=ok"
fi

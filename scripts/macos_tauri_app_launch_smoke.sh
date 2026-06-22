#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS Tauri launch smoke skipped: not running on macOS"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_app_path() {
  local candidate
  for candidate in \
    "${ROOT}/src-tauri/target/universal-apple-darwin/release/bundle/macos/VEX.app" \
    "${ROOT}/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/VEX.app" \
    "${ROOT}/src-tauri/target/x86_64-apple-darwin/release/bundle/macos/VEX.app" \
    "${ROOT}/src-tauri/target/aarch64-apple-darwin/debug/bundle/macos/VEX.app" \
    "${ROOT}/src-tauri/target/x86_64-apple-darwin/debug/bundle/macos/VEX.app"; do
    if [[ -x "${candidate}/Contents/MacOS/app" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  printf '%s\n' "${ROOT}/src-tauri/target/aarch64-apple-darwin/debug/bundle/macos/VEX.app"
}

APP_PATH="${APP_PATH:-$(default_app_path)}"
APP_BIN="${APP_PATH}/Contents/MacOS/app"
RUN_SECONDS="${RUN_SECONDS:-8}"

if [[ ! -x "${APP_BIN}" ]]; then
  echo "macOS Tauri launch smoke failed: app binary is missing: ${APP_BIN}" >&2
  exit 1
fi

if [[ "${APP_PATH}" == "/Applications/VEX.app" ]] \
  && pgrep -f '/Applications/VEX.app/Contents/MacOS/app' >/dev/null 2>&1; then
  echo "macOS Tauri launch smoke skipped: installed VEX.app is already running"
  exit 0
fi

log_file="$(mktemp)"
pid=""
cleanup() {
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${log_file}"
}
trap cleanup EXIT

"${APP_BIN}" >"${log_file}" 2>&1 &
pid="$!"

sleep "${RUN_SECONDS}"
if ! kill -0 "${pid}" >/dev/null 2>&1; then
  exit_code=0
  wait "${pid}" >/dev/null 2>&1 || exit_code=$?
  pid=""
  if [[ "${exit_code}" -eq 0 ]] \
    && pgrep -f '/Applications/VEX.app/Contents/MacOS/app' >/dev/null 2>&1; then
    echo "macOS Tauri launch smoke skipped: app handed off to the already running installed VEX.app"
    exit 0
  fi
  echo "macOS Tauri launch smoke failed: app exited before ${RUN_SECONDS}s" >&2
  cat "${log_file}" >&2
  exit 1
fi

echo "macOS Tauri launch smoke passed"

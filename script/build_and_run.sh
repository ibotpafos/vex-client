#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/macos-native/build/VEXNativeMac.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/VEXNativeMac"

stop_project_build() {
  /usr/bin/pkill -f "${APP_BINARY}" >/dev/null 2>&1 || true
}

build_app() {
  "${ROOT_DIR}/scripts/build_native_macos_app.sh"
  /usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"
}

open_app() {
  /usr/bin/open -n "${APP_BUNDLE}"
}

stop_project_build
build_app

case "${MODE}" in
  --run|run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "${APP_BINARY}"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "VEXNativeMac"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "VEXNativeMac"'
    ;;
  --verify|verify)
    open_app
    sleep 1
    /usr/bin/pgrep -f "${APP_BINARY}" >/dev/null
    ;;
  *)
    echo "usage: $0 [--run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

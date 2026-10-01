#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---verify}"
case "$MODE" in
  --verify|--logs|--live) ;;
  *) echo "usage: $0 [--verify|--logs|--live]" >&2; exit 2 ;;
esac
# Do not stop a running client: it may own the user's active VPN tunnel.
if /usr/bin/pgrep -x VEXNativeMac >/dev/null; then
  echo "VEX is already running. Close it explicitly before building/relaunching." >&2
  exit 1
fi
bash "$ROOT/scripts/build_native_macos_app.sh"
APP_PATH="$ROOT/macos-native/build/VEXNativeMac.app"
export APP_PATH
if [[ "$MODE" == "--live" ]]; then
  /usr/bin/open -n "$APP_PATH"
else
  bash "$ROOT/scripts/smoke_native_macos_launch.sh"
  if [[ "$MODE" == "--logs" ]]; then
    /usr/bin/log stream --info --style compact --predicate 'process == "VEXNativeMac"'
  fi
fi

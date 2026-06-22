#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_PORT="${VEX_WEB_PORT:-3001}"
PROXY_PORT="${VEX_DEV_PROXY_PORT:-3011}"

cd "$ROOT_DIR"

node scripts/dev_prod_api_proxy.mjs &
proxy_pid="$!"

cleanup() {
  kill "$proxy_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

EXPO_PUBLIC_VEX_API_BASE_URL="http://127.0.0.1:${PROXY_PORT}" \
EXPO_PUBLIC_VEX_SUPPORT_URL="${EXPO_PUBLIC_VEX_SUPPORT_URL:-https://vexguard.app/support}" \
npx expo start --web --port "$WEB_PORT"

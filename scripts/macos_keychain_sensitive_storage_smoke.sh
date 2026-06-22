#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS Keychain smoke skipped: not running on macOS"
  exit 0
fi

service="app.vex.vpn.desktop.sensitive-storage.smoke"
key="vex.auth.smoke.$(date +%s).$$"
payload="$(od -An -tx1 -N48 /dev/urandom | tr -d ' \n')"
add_error_log="$(mktemp)"

cleanup() {
  security delete-generic-password -a "$key" -s "$service" >/dev/null 2>&1 || true
  rm -f "$add_error_log"
}
trap cleanup EXIT

if ! printf '%s\n%s\n' "$payload" "$payload" \
  | security add-generic-password -a "$key" -s "$service" -U -w >/dev/null 2>"$add_error_log"; then
  cat "$add_error_log" >&2
  exit 1
fi

readback="$(security find-generic-password -a "$key" -s "$service" -w)"
if [[ "$readback" != "$payload" ]]; then
  echo "macOS Keychain smoke failed: readback mismatch" >&2
  exit 1
fi

cleanup
if security find-generic-password -a "$key" -s "$service" -w >/dev/null 2>&1; then
  echo "macOS Keychain smoke failed: temporary item was not deleted" >&2
  exit 1
fi

echo "macOS Keychain sensitive storage smoke passed"

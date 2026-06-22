#!/usr/bin/env bash
set -euo pipefail

HELPER_DIR="/Library/Application Support/VEX VPN/helper"
COMMAND_FILE="$HELPER_DIR/command"
RESULT_FILE="$HELPER_DIR/result"
LOG_FILE="$HELPER_DIR/last.log"
AWG_QUICK="$HELPER_DIR/awg-quick.sh"
CONFIG_FILE="$HELPER_DIR/config-path"

touch "$LOG_FILE"

while true; do
  if [[ -f "$COMMAND_FILE" ]]; then
    action="$(cat "$COMMAND_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$action" ]] || { sleep 0.25; continue; }
    : > "$COMMAND_FILE"
    chmod 666 "$COMMAND_FILE"
    config="$(cat "$CONFIG_FILE" 2>/dev/null || true)"
    : > "$RESULT_FILE"
    chmod 666 "$RESULT_FILE"

    if [[ "$action" == "up" || "$action" == "down" ]]; then
      if "$AWG_QUICK" "$action" "$config" >"$LOG_FILE" 2>&1; then
        printf '0\n' > "$RESULT_FILE"
      else
        code="$?"
        printf '%s\n' "$code" > "$RESULT_FILE"
      fi
      chmod 666 "$RESULT_FILE" "$LOG_FILE"
    else
      printf 'unknown helper action: %s\n' "$action" > "$LOG_FILE"
      printf '64\n' > "$RESULT_FILE"
      chmod 666 "$RESULT_FILE" "$LOG_FILE"
    fi
  fi
  sleep 0.25
done

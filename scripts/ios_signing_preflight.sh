#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR"

fail() {
  echo "error: $*" >&2
  exit 1
}

detect_team_id() {
  security find-identity -v -p codesigning |
    sed -n 's/.*Apple Development: .* (\([A-Z0-9]\{10\}\)).*/\1/p' |
    head -1
}

TEAM_ID="${IOS_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="$(detect_team_id || true)"
fi

[ -n "$TEAM_ID" ] || fail "No Apple Development Team ID found. Set IOS_DEVELOPMENT_TEAM=XXXXXXXXXX or add an Apple Development certificate to Keychain."

echo "== Apple code signing identities =="
security find-identity -v -p codesigning || true

echo "== Signing preflight =="
echo "Using Team ID: $TEAM_ID"
echo "Checking iOS device signing for VEX and VexVpnTunnel..."

set +e
output="$(
  cd "$APP_DIR" &&
    xcodebuild \
      -workspace ios/VEX.xcworkspace \
      -scheme VEX \
      -configuration Debug \
      -sdk iphoneos \
      -destination 'generic/platform=iOS' \
      "DEVELOPMENT_TEAM=$TEAM_ID" \
      -allowProvisioningUpdates \
      build 2>&1
)"
status=$?
set -e

printf '%s\n' "$output" |
  grep -E 'No Account|No profiles|Cannot create|does not support|Provisioning profile|requires a development team|error:|BUILD FAILED|BUILD SUCCEEDED' || true

if [ "$status" -ne 0 ]; then
  fail "iOS signing preflight failed for Team ID $TEAM_ID"
fi

echo "iOS signing preflight finished"

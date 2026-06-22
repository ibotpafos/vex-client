#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ -n "${IOS_DEVELOPMENT_TEAM:-}" ] || fail "Set IOS_DEVELOPMENT_TEAM to a paid Apple Developer Team ID."

cd "$APP_DIR"

npm run ios:sync-vpn-extension
npm run ios:preflight
npm run ios:signing-preflight

xcodebuild \
  -workspace ios/VEX.xcworkspace \
  -scheme VEX \
  -configuration "${IOS_CONFIGURATION:-Debug}" \
  -sdk iphoneos \
  -destination "${IOS_DESTINATION:-generic/platform=iOS}" \
  "DEVELOPMENT_TEAM=$IOS_DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  build

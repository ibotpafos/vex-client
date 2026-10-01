#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/vex-native-offline.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SOURCES="$ROOT/macos-native/Sources/VEXNativeMac"
swiftc -swift-version 5 -parse-as-library -o "$BUILD/offline" \
  "$SOURCES/Models/VEXModels.swift" \
  "$SOURCES/Services/VEXAPIClient.swift" \
  "$SOURCES/Services/HelperDisconnectConfirmation.swift" \
  "$SOURCES/Services/CustomerRealtimeService.swift" \
  "$SOURCES/Services/AppSensitiveFileStore.swift" \
  "$SOURCES/Services/VEXKeychainStore.swift" \
  "$SOURCES/Services/VEXSessionStore.swift" \
  "$ROOT/macos-native/Tests/OfflineHarness/main.swift"
"$BUILD/offline"
python3 "$ROOT/scripts/tests/test_macos_build_failures.py"
python3 "$ROOT/scripts/tests/test_macos_helper_socket.py"
python3 "$ROOT/scripts/tests/test_vex_country_groups.py"
bash "$ROOT/scripts/test_awg31_macos_admission.sh"
python3 "$ROOT/scripts/tests/test_macos_release_safety.py"
python3 "$ROOT/scripts/tests/test_macos_signing_order.py"

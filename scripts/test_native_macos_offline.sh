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
python3 "$ROOT/scripts/tests/test_macos_notification_policy.py"
python3 "$ROOT/scripts/tests/test_macos_notification_service.py"
python3 "$ROOT/scripts/tests/test_macos_realtime_notification_wiring.py"
python3 "$ROOT/scripts/tests/test_macos_authenticated_connect_boundaries.py"
python3 "$ROOT/scripts/tests/test_macos_autopilot_auth_generation.py"
python3 "$ROOT/scripts/tests/test_macos_customer_event_callbacks.py"
python3 "$ROOT/scripts/tests/test_macos_authenticated_operation_lifecycle.py"
python3 "$ROOT/scripts/tests/test_macos_billing_session_generation.py"
python3 "$ROOT/scripts/tests/test_macos_prepared_tunnel_auth_generation.py"
python3 "$ROOT/scripts/tests/test_macos_autopilot_boundary_matrix.py"
python3 "$ROOT/scripts/tests/test_macos_handshake_auth_generation.py"
python3 "$ROOT/scripts/tests/test_macos_profile_cache_ownership.py"
python3 "$ROOT/scripts/tests/test_macos_push_registration_service.py"
python3 "$ROOT/scripts/tests/test_macos_push_api_contract.py"
python3 "$ROOT/scripts/tests/test_macos_push_consent.py"
python3 "$ROOT/scripts/tests/test_macos_push_event_queue.py"
python3 "$ROOT/scripts/tests/test_macos_push_event_intake.py"
python3 "$ROOT/scripts/tests/test_macos_push_secure_store.py"
python3 "$ROOT/scripts/tests/test_macos_psk_rotation_api_contract.py"
python3 "$ROOT/scripts/tests/test_macos_explicit_signing.py"
python3 "$ROOT/scripts/tests/test_macos_signing_order.py"

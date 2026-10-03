#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolve the existing test root before fixtures append not-yet-created paths.
# /tmp and /var may be symlinks on macOS. Secure-store production code must
# continue rejecting symlink ancestors rather than weakening its no-follow gate.
TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
export TMPDIR
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/vex-native-offline.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SOURCES="$ROOT/macos-native/Sources/VEXNativeMac"
swiftc -swift-version 5 -parse-as-library -o "$BUILD/offline" \
  "$SOURCES/Models/VEXModels.swift" \
  "$SOURCES/Services/NativePSKIdentifier.swift" \
  "$SOURCES/Services/VEXAPIClient.swift" \
  "$SOURCES/Services/HelperDisconnectConfirmation.swift" \
  "$SOURCES/Services/CustomerRealtimeService.swift" \
  "$SOURCES/Services/AppSensitiveFileStore.swift" \
  "$SOURCES/Services/VEXKeychainStore.swift" \
  "$SOURCES/Services/VEXSessionStore.swift" \
  "$ROOT/macos-native/Tests/OfflineHarness/main.swift"
"$BUILD/offline"
python3 "$ROOT/scripts/tests/test_macos_offline_tmpdir.py"
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
python3 "$ROOT/scripts/tests/test_macos_admitted_profile_binding.py"
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
python3 "$ROOT/scripts/tests/test_macos_psk_preparation.py"
python3 "$ROOT/scripts/tests/test_macos_explicit_signing.py"
python3 "$ROOT/scripts/tests/test_macos_signing_order.py"
python3 "$ROOT/scripts/tests/test_macos_public_anchor_packaging.py"
python3 "$ROOT/scripts/tests/test_macos_repository_public_anchor.py"

# PSK source-only runtime gates; no app/helper/VPN launch or live API/APNs.
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
python3 "$ROOT/scripts/tests/test_macos_psk_staged_profile_store.py"
python3 "$ROOT/scripts/tests/test_macos_psk_rotation_validation.py"
python3 "$ROOT/scripts/tests/test_macos_psk_profile_authorization.py"
python3 "$ROOT/scripts/tests/test_macos_normal_profile_authorization.py"
python3 "$ROOT/scripts/tests/test_macos_normal_profile_persistence.py"
python3 "$ROOT/scripts/tests/test_macos_readonly_profile_reconciliation.py"
python3 "$ROOT/scripts/tests/test_macos_ordinary_push_reconciliation.py"
python3 "$ROOT/scripts/tests/test_macos_active_normal_pending_stage.py"
python3 "$ROOT/scripts/tests/test_macos_normal_pending_preflight.py"
python3 "$ROOT/scripts/tests/test_macos_pf_armed_replacement.py"
python3 "$ROOT/scripts/tests/test_macos_protected_replacement.py"
python3 "$ROOT/scripts/tests/test_macos_protected_rpc.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_protected_owner_transfer.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_protected_pre_stage_consent.py"
python3 "$ROOT/scripts/tests/test_macos_pre_stage_client_consent.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_pre_stage_cancel_receipt.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_pre_stage_cancel_client.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_stage_cancel_retirement.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_post_promotion_retirement.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_client_restart.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_client_restart_material.py"
rtk proxy python3 "$ROOT/scripts/tests/test_macos_client_journal_continuation.py"
python3 "$ROOT/scripts/tests/test_macos_protected_commit_receipt_file.py"
python3 "$ROOT/scripts/tests/test_macos_protected_coordinator.py"
python3 "$ROOT/scripts/tests/test_macos_durable_promotion.py"
python3 "$ROOT/scripts/tests/test_macos_pending_journal_runtime.py"
python3 "$ROOT/scripts/tests/test_macos_helper_readiness_refresh.py"
python3 "$ROOT/scripts/tests/test_macos_normal_cache_model.py"
python3 "$ROOT/scripts/tests/test_macos_psk_event_consumer.py"
python3 "$ROOT/scripts/tests/test_macos_psk_profile_preparation.py"
python3 "$ROOT/scripts/tests/test_macos_psk_appstate_cutover.py"
python3 "$ROOT/scripts/tests/test_macos_psk_signed_stage_chain.py"

# Android preview OTA — 2026-10-01

Status: native apply/rollback observed; visual notices remain a release blocker.
Production channel, released APK 1.0.59/1005967, DNS and VPN infrastructure were not changed.

## Executed acceptance

- Exactly one Android-only EOAS 2.3.23 preview publish was executed from f8104fe,
  runtime 1.0.60. Source, origin commit/UUID, RSA signature and all 33 exported
  bundle/asset hashes match. Expo GraphQL owns channel mappings, not EOAS updates.
- Android verified the signature, downloaded that update and remained connected:
  same Dev process, native VPN present, restartCount 0 while the update was pending.
  After explicit disconnect, native restartCount became 1. Selecting Russia showed
  the new Moscow backdrop and Russian subtitle, absent from the embedded APK.
- The single preview rollback command reached the origin but its CLI timed out.
  No retry occurred. Read-only origin/source proof and a signed rollback-to-embedded
  directive completed its existing receipt. The origin requires the verified APK's
  embedded update ID header, as does the native SDK.
- Android received the rollback while VPN stayed connected with restartCount 1.
  After explicit disconnect, restartCount became 2; Russia returned the embedded
  empty/default backdrop and RU subtitle. Auto-selection was restored; final VPN off.

## Defect and scoped fix

The OTA Host lacked intrinsic vertical sizing: native download/reload succeeded,
while progress/ready/completion cards were invisible on this phone. Add the maintained
Expo UI Host matchContents vertical option; retain the existing VPN/AppState guard.
The source rollback probe returns no vertical measurement, the fixed copy enables it,
and a disposable restored copy returns the pristine behavior/hash. Full npm run check
passes. This is not yet on-device acceptance of the fixed notices; the inline TODO
keeps the visual release gate explicit. SDK reference:
https://docs.expo.dev/versions/v56.0.0/sdk/ui/universal/host/

## Remaining gates

1. Build the exact fixed-source signed candidate; install isolated Dev variant and
   prove visible download/ready/success/rollback notices, including one-time success.
2. Finish newer Android, long-idle/process/network-transition and actual egress/leak
   acceptance plus protected user-failure triage.
3. Review/merge only verified source and publish only after every release gate passes;
   retain production rollback and post-release telemetry. No second preview publish
   is implied by the duplicated approval message.

Private device logs, APKs and four-role ledgers stay outside Git under
/Volumes/D/Projects/mobile-transactions/android-release-20260930/preview-ota/.

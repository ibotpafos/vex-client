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

## Separately approved second preview — physical acceptance

- Tested source: `2ce0a26075ceed1b95cdc8dcfab9024f0673c20e`, Dev APK SHA-256 `68d9b110928914fbcb147ff0de83babd43cede88f0b9f34792da7fa539a3cdc3`. Current follow-up changes remove the now-completed notice TODO and record evidence only; do not relabel the retained APK as a later source.
- Signed production candidate run36798673929 passed checksum, production signer, both ABIs and upgrade from published1.0.59; it was not released or installed over production.
- One new Android preview OTA, signed manifest and all33 file bytes verified against retained export. Exact update5934cd56-3f77-dabd-6c56-56fe7a152d3a.
- Android9: ready notice now visible, including VPN-deferral explanation. 25 connected samples and no native reload. Manual disconnect led to restartCount1 and visible **Обновлено** / **Новая версия запущена и готова к работе.**; notice then expired.
- One distinct signed rollback: commitTime2026-10-01T01:26:02Z. 16 connected samples with no reload; manual disconnect led to restartCount2 and visible **Стабильная версия восстановлена** / **Безопасная встроенная версия запущена и готова к работе.**; notice then expired.
- Phone left disconnected with automatic server selection. Installed production APK remains byte-identical to published1.0.59, SHA-256 `7eb5c6b5f9e7a76a69f25612fd85396305f279c399c47fcbbc69190ea3dd4150`.
- Downloading notice was too brief to capture. No Doze/process-death/network-switch/real-egress/leak/speed/newer-Android acceptance is claimed. Those release gates remain required.
- Legacy EOAS rollback still carries a CLI timeout flag although its child reaped0 and signed origin proves rollback. Operator regression guard now separates timeout from normal completion; no duplicate write was attempted. Local TTY lifecycle investigation is still open.
- Production channel, DNS and VPN infrastructure unchanged. No third preview publication is authorized by this test approval.

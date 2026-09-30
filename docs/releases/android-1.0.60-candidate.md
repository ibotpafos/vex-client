# Android 1.0.60 candidate — not published

Candidate: Android version 1.0.60, internal build 68, versionCode 1006068,
OTA runtime 1.0.60. iOS and frozen native Windows metadata are unchanged.

Published baseline remains Android 1.0.59, versionCode 1005967. The earlier
signed 1.0.59/68 artifact is not the 1.0.60 artifact and must not be renamed.

The release PR must stay draft until the remaining device/OTA/customer gates
pass. Signing run 36707722877 built updated-dependency source commit 2231c17;
APK SHA-256 is b3f8fcd5f947d9dec3a8bf84627912b8cfbf06a23410fcfb267ead9f1f25fdaa.
The sidecar, production signer, package, both ABIs and published-baseline upgrade
compatibility passed. `versions.json` is now bound to that verified checksum
and the candidate signature URL; this does not publish the download URL.

TODO: Prove device installation and signed preview OTA
apply/connected-VPN deferral/rollback before promoting the customer release.
The Android 9 device is connected and charging, but these acceptance gates
have not yet passed; broader Android and network transition acceptance also
remains open.

## Preview-only follow-up, 2026-09-30

- The incomplete Expo mapping receipt was inspected without adopting or deleting
  its pre-existing branch. A fresh channel-only plan created preview; live
  manifest checks returned 200 for preview and production. The exact owned,
  empty channel was removed by the guarded rollback, then freshly planned and
  recreated. The original branch and production snapshot stayed unchanged.
- An OTA-enabled QA APK built from 4167712 uses only the preview channel,
  runtime 1.0.60 and the embedded signing certificate. It keeps the Dev package
  and signer, so it can replace Dev without replacing production 1.0.59.
  This is a test artifact, not the production-release-signed APK.
- A 30.9-second HOME/background test retained one OS VPN and the Dev process in
  all four samples. Returning to Dev showed Подключено; explicit cleanup left
  zero OS VPNs. UIAutomator null-root failures and a wrong connected-button
  label were test-harness errors, retained separately; this is not Doze,
  process-recovery, network-transition or tunneled-egress acceptance.
- Add a generated Moscow dusk backdrop only for normalized RU locations and
  translate Moscow/Россия in the home copy. Existing DE/FI/NL and unknown
  fallback behavior remain unchanged. Source baseline/modified/rollback and
  exact binary patch reconstruction pass; full npm run check passes.
  The picture is a JS/asset-only change and is not in either previously built
  APK. Do not bind the older APK checksum to this newer source or claim it
  has been installed via OTA.
- Owner approved one signed Android-only preview OTA publish/apply/rollback
  test; duplicated approval replies do not authorize duplicated updates.
  No OTA was published. The existing compatible publisher is eoas 2.3.23;
  local Expo token/session is unavailable. Provision its authenticated execution
  through the gated operator, keep the signing key on the origin, and verify
  the rollback path before starting a publish. Do not upgrade the production
  server protocol merely to use the installed v3 CLI.

TODO: Finish the approved authenticated preview publisher preflight and prove
signed apply, connected-VPN deferral and OTA rollback on the attached device.
Customer release remains gated; the prior TODO and broader acceptance remain.

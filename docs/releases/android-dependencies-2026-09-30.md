# Android dependency refresh — 2026-09-30

Stay on the stable Expo SDK 57 / React 19.2.3 / React Native 0.86.3 matrix.
The npm registry and Expo recommended versions were checked before editing.
No blind major upgrades, forced peer resolution, native Windows changes,
customer publication, DNS or VPN changes are included.

Updated version floors: Expo 57.0.26, Expo UI 57.0.21, Constants 57.0.20,
Linking 57.0.11, Notifications 57.0.21, Router 57.0.24, Updates 57.0.24,
Sentry React Native 8.28.0, TanStack Query 5.104.0, Lucide 1.49.0,
Screens 4.26.2, React Native Web 0.21.3, eoas 3.2.5 and tsx 4.23.15.
Keep React types on 19.2.x instead of pulling 19.3 types into the SDK matrix.
The fingerprint override/resolution is now 0.20.13, matching SDK 57;
Metro 56.0.2 is deliberately retained because Expo 57.0.26 itself requires it.
The legacy production OTA publisher remains pinned to its reviewed compatible
CLI version; updating the development dependency does not publish an update.

The locked dependency tree is refreshed. Registry audit: baseline had four
findings (two high, two moderate); modified lock/install had zero findings.
This is the npm audit result, not a guarantee that all possible defects are gone.
`expo install --check`, direct dependency tree, TypeScript, ESLint and upstream
AmneziaWG contract passed. All 22 functional unit command groups passed.
The release-metadata gate initially rejected the empty candidate checksum;
it was not relaxed. The verified production-signed artifact now supplies the
actual checksum/signature metadata. Expo Doctor passed 19 of 20 checks;
its only failed check is unavailable local CocoaPods (`pod` exit 127), not
an Android dependency failure. Native iOS build acceptance is not claimed.

A fresh isolated development APK built successfully: com.vexguard.app.dev,
1.0.60.dev / versionCode 1006068, arm64-v8a, complete JS bundle 6316568 bytes,
SHA-256 01bb4ade9d416a382d8408161be606ba52af50d73d5f543002a5efc9b372091e.
It was not installed over the production package or published to customers.

Disposable source verification used the same input for baseline, modified and
rollback. Baseline/rollback: Expo ~57.0.24, Sentry ^8.21.0, fingerprint 0.19.4.
Modified: Expo ~57.0.26, Sentry ^8.28.0, fingerprint 0.20.13. Both package and
lockfile restored hashes match baseline; patch reconstruction matches modified.
Evidence supplements extend the existing version transaction under
`/private/tmp/vex-android-release-candidate-68-20260930/dependencies/`.

Production signing run 36707722877 succeeded for source commit 2231c17. Both
ABIs, production signer, sidecar and upgrade compatibility passed; signed APK
SHA-256 is b3f8fcd5f947d9dec3a8bf84627912b8cfbf06a23410fcfb267ead9f1f25fdaa.
Candidate metadata is bound to this artifact; the download is not published.

TODO: Prove on-device signed OTA apply/deferral/rollback, modern Android/network
transitions and protected customer failure triage before customer release.

# Android OTA status and release gate — 2026-09-29

The existing client already uses the maintained `expo-updates` package, a signed custom update URL, and a guarded runtime/channel configuration. No replacement update library was added. The production build is distinct from the local `.dev` APK; OTA is deliberately disabled in the latter.

## Confirmed defects and change

- The startup OTA overlay downloaded an update and showed a ready banner but never confirmed that the downloaded revision actually launched. It now records the target update ID/runtime before reload and shows **Обновлено** only if the next non-emergency launch matches. A rollback to the embedded bundle has its own confirmation. The marker is consumed once and removed on reload failure.
- The JS check treated a valid `isRollBackToEmbedded` response as “no update”; it now fetches the rollback directive and preserves the existing safe-reload gate. An active VPN is never interrupted to apply OTA; the banner explains why it is waiting.
- Download status now uses `expo-updates`' own progress when available. Internal exception messages are no longer shown to users. Native on-load checks/downloads are reflected in the same overlay, and duplicate JS checking is skipped while the native updater is busy.
- The update-center **Проверить OTA** action only refreshed native APK metadata. It now calls Expo's OTA check/fetch, handles a runtime-incompatible/no-update response and blocks duplicate taps.
- The local APK verifier falsely reported that `libwg.so` was missing because `printf | grep -q` could SIGPIPE under `pipefail`. A large-manifest fixture reproduces the failure; the verifier now checks the captured entry list without a pipe. The actual built APK contained all three required VPN libraries.

## Evidence and limits

- `npm run check`: unit/contract, upstream AWG, TypeScript and ESLint. `tests/ota-completion.test.mjs` covers exact revision/runtime, rollback, emergency launch and invalid markers. `tests/android-apk-verifier.test.mjs` covers a 6,000-entry archive and the actual verifier.
- Local APK build and `verify_android_apk.sh` passed for `com.vexguard.app.dev` 1.0.59.dev, arm64-v8a, all three VPN libraries and the JS bundle. Final APK SHA-256: `c99f89cafbd695721cd37536b44ae6876d900fc1e6925c2b43e2421065d96317`. This does not replace a production signing-certificate check. It installed alongside the production package on Android 9 Mi A1; the home screen visibly launched, VPN was disconnected, and a bounded 372-line process logcat sample had zero `FATAL EXCEPTION`, `ReactNativeJS: Error` or `AndroidRuntime:` lines. The local APK **cannot** exercise real OTA because updates are disabled for development builds.
- Read-only VEX release truth: public health, downloads and update metadata were OK, but production deploy status and Android OTA acceptance timed out. A separate 30-second-targeted acceptance command exited 1 with `urllib.error.URLError`; no OTA acceptance result can be claimed. No production APK, OTA, manifest, server, customer account, or feature flag was changed.

Before any production publication: build an OTA-enabled preview with the exact installed runtime and signing certificate, publish a harmless preview revision, verify download → safe deferred reload → matching update ID → one-time success notice on a real device, verify rollback and connected-VPN deferral, then re-run release truth and production health. Publish only the exact reviewed source/runtime with rollback evidence. A green local `.dev` build alone is **not** release acceptance.

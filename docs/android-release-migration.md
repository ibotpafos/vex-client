# Android release families and upgrade gate

The canonical client is `com.vexguard.app`. Keep that identity and its existing
signing certificate. Do not rename it back or replace signing checks to make an
unrelated APK look like an update.

## Verified distribution state (2026-09-04)

| APK | Package | Certificate SHA-256 | ABI |
| --- | --- | --- | --- |
| Public 1.0.55 / 1005557 | com.vexguard.client | 0548ea2bafe6179226d2dde5ba50e2a5a6dabac1e90df655c8a58c042d046cca | arm64-v8a, armeabi-v7a |
| Candidate 1.0.56 / 1005663 | com.vexguard.app | cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470 | arm64-v8a |

This is a separate-app migration, not an in-place upgrade. Install the new app
alongside the old one, sign in normally, and verify VPN before the user removes
the old app. Do not promise preserved local login, preferences, or VPN state
across package IDs. Do not uninstall the old app automatically.

The currently shared stable release feed must not be repointed to this
incompatible APK. Before publishing future automatic updates for the new family,
the backend/client release contract needs package-family targeting and backward
compatibility for requests without an application ID. A successful same-family
canary alone does not establish that targeting. A 32-bit device also needs a
compatible ABI build; do not label an arm64-only artifact universal.

## Pre-publication compatibility check

Use final signed APKs, not unsigned build intermediates:

```sh
export ANDROID_HOME=/path/to/android-sdk
export JAVA_HOME=/path/to/jdk17
npm run android:verify-upgrade -- /path/to/installed-family.apk /path/to/candidate.apk
```

Optional `AAPT_BIN` and `APKSIGNER_BIN` override SDK build-tools/36.0.0 paths.
Exit 0 means only that these conservative static checks pass. Exit 1 reports
incompatible package, signer, build, ABI, or minimum SDK. Exit 2 is an inspection
error and must also stop release. The command never publishes or edits an APK.

The verifier rejects different certificate sets even if a signing lineage could
permit rotation on some OS versions. Validate any planned rotation separately;
do not treat this conservative rejection as proof that a lineage is invalid.

Example observed results:
- Public 1005557 -> candidate1005663: exit1, PACKAGE_CHANGED, SIGNER_CHANGED,
  ABI_REMOVED.
- Signed com.vexguard.app1005662 ->1005663: exit0.

Still verify actual installation, session persistence, Google login, VPN traffic,
notification permission/token lifecycle, device/ABI matrix and release audience.
Fixtures, static checks and emulator results are not substitutes for physical
cellular/IPv6 acceptance.

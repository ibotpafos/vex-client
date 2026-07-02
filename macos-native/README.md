# VEX Native macOS

This is the first SwiftUI-native macOS client slice for VEX. It intentionally
reuses the existing privileged `vex-helper` daemon instead of creating a second
VPN runtime.

Current scope:

- SwiftUI `.app` bundle.
- Ad-hoc local code signing with `codesign -s -`.
- Helper status polling through `/var/run/vex-helper.sock`.
- Connect/disconnect commands through the existing helper protocol.
- Sparkle 2 update checks and appcast-based release archives.

Non-goals for this slice:

- No mandatory Apple Developer ID distribution.
- No mandatory notarization.
- No replacement for the current Tauri/Expo production client yet.

Build locally:

```sh
bash scripts/build_native_macos_app.sh
open macos-native/build/VEXNativeMac.app
```

Build a local installer package that drops the app into `/Applications` and
installs the privileged helper during package postinstall:

```sh
bash scripts/build_native_macos_pkg.sh
open macos-native/build/pkg/VEXNativeMac-0.1.0-1.pkg
```

This is the only path that can truly install the helper during installation.
Drag-and-drop `.app` or `.dmg` flows do not have a postinstall hook, so they
still rely on the app's first-launch auto-bootstrap path.

Build a local Sparkle release smoke archive:

```sh
VEX_NATIVE_VERSION=0.1.1 \
VEX_NATIVE_BUILD=2 \
VEX_SPARKLE_ALLOW_EPHEMERAL_KEYS=1 \
bash scripts/build_native_macos_sparkle_release.sh
```

The ephemeral key mode is only for local validation. Do not publish an appcast
created with an ephemeral key.

The release script validates the packaged `Info.plist`, verifies the generated
Sparkle appcast signature/version/download URL, writes SHA-256 sidecars for the
zip and appcast, and emits `release-manifest.json` next to the archives.

Production Sparkle setup:

```sh
macos-native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account app.vex.vpn.native
```

Put the public key and private-key file path in ignored `.env.sparkle.local`:

```sh
VEX_SPARKLE_PUBLIC_ED_KEY=...
VEX_SPARKLE_PRIVATE_ED_KEY_FILE=/secure/path/vex-sparkle-private-key.txt
VEX_SPARKLE_KEY_ACCOUNT=app.vex.vpn.native
VEX_SPARKLE_DOWNLOAD_URL_PREFIX=https://vexguard.app/downloads/native-macos/
```

Production release command:

```sh
VEX_NATIVE_VERSION=0.1.1 \
VEX_NATIVE_BUILD=2 \
VEX_SPARKLE_PRODUCTION=1 \
bash scripts/build_native_macos_sparkle_release.sh
```

This is the same trust model as the current Tauri updater: Sparkle verifies the
update archive with the Sparkle EdDSA key, while the app itself may still be
ad-hoc signed for internal/manual distribution. After the app is trusted locally,
Sparkle updates can work without Apple Developer ID.

Internal release without Apple Developer ID:

```sh
VEX_NATIVE_VERSION=0.1.1 \
VEX_NATIVE_BUILD=2 \
bash scripts/build_native_macos_internal_release.sh
```

This builds the `.app`, unsigned `.pkg`, Sparkle archive, appcast, checksums, and
release manifest, then runs the internal preflight. It intentionally rejects
ephemeral Sparkle keys: use a stable Sparkle EdDSA key even before Apple Developer
ID is available.

To require Developer ID signing for a Gatekeeper-ready release:

```sh
VEX_NATIVE_VERSION=0.1.1 \
VEX_NATIVE_BUILD=2 \
VEX_SPARKLE_PRODUCTION=1 \
VEX_SPARKLE_REQUIRE_DEVELOPER_ID=1 \
VEX_CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
bash scripts/build_native_macos_sparkle_release.sh
```

Optional notarization:

```sh
VEX_NOTARIZE=1 \
VEX_NOTARY_PROFILE=vex-notary \
bash scripts/build_native_macos_sparkle_release.sh
```

`VEX_NOTARIZE=1` submits a zipped app to Apple, staples the notarization ticket
to the `.app`, then creates the final Sparkle zip and appcast. Local ad-hoc
builds should leave notarization disabled.

Without Apple Developer ID this app is suitable for local/manual testing only.
Public distribution without Gatekeeper friction still requires Developer ID
signing and notarization.

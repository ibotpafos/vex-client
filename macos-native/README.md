# VEX Native macOS

This is the SwiftUI-native macOS client for VEX. Its privileged
`VEXPrivilegedHelper` is also implemented in Swift and built as a separate
SwiftPM executable with an independent native helper and release pipeline.

Current scope:

- SwiftUI `.app` bundle.
- Stable local VEX signing when the existing v4 signing materials are present,
  with ad-hoc signing only as a fallback on machines without them.
- Helper status polling through `/var/run/vex-helper.sock`.
- Connect/disconnect commands through the stable text helper protocol.
- Transactional PF fail-open teardown, owner watchdog and continuous tunnel
  health supervision in `VEXHelperCore`.
- Sparkle 2 update checks and appcast-based release archives.

Non-goals for this slice:

- No mandatory Apple Developer ID distribution.
- No mandatory notarization.
- Real PF/route/DNS/launchd fault injection still requires a disposable macOS VM.

Build and verify locally without touching an active VPN:

```sh
./script/build_and_run.sh --verify
```

The Codex Run action uses this same entrypoint. It refuses to terminate an
existing client. Its default launch uses `--offline-smoke`: no session restore,
helper startup, update checks, deep-link registration, or enabled VPN controls.
Use `--live` only for an intentional normal launch. A normal launch can attach
to a retained tunnel, so it is not an isolated verification step.

The packager propagates compiler failures, takes binaries/frameworks/resources
from the exact successful build output, and runs `--resource-bundle-probe`.
Country geometry resolves from `Contents/Resources`; a missing resource bundle
returns a missing-resource result instead of SwiftPM's fatal assertion.

Offline regression tests (Command Line Tools supported):

```sh
bash scripts/test_native_macos_offline.sh
python3 scripts/tests/test_macos_packaged_resources.py macos-native/build/VEXNativeMac.app
```

These tests use intercepted HTTP, temporary files, an in-memory keychain, and
fake helper sockets. They do not contact the system helper or change network
state. They complement the full `swift test --package-path macos-native` suite,
which requires Xcode/XCTest.

On the VEX build Mac, the builder unlocks a private build keychain derived from
the existing `VEX Self-Signed Application` v4 key and restores the original
user keychain search list when finished. The resulting certificate SHA-256 is
`967a977828ebb8c4b713abeeb3844248a42bfaa8f08167cf217ca524e7a0e872`.
The helper policy also retains the newer local certificate and Apple Team ID
paths. Other machines fall back to ad-hoc signing for offline validation only.
See [the consolidation report](../docs/verification/2026-09-22-macos-consolidation.md)
for source provenance and the exact verification limits.

## Live-VPN-safe test plan

Before any installer or connection smoke, capture `scutil --nc list` and the
read-only `--helper-status-probe`. If INCY, VEX, or any other VPN is connected,
keep that tunnel unchanged: do not run helper `down`, network reset, tunnel
teardown, route/DNS/PF mutation, installer/postinstall, or cleanup commands.
Limit verification to bundle/signature inspection, decoder probes, build/tests,
`--helper-install-state-probe`, and read-only launch/crash observation. Run the
full install -> connect -> disconnect acceptance only on a disposable host or
after the active tunnel is no longer part of the protected test baseline.

`build_native_macos_app.sh` first builds a universal Swift helper through
`scripts/build_swift_macos_helper.sh` and packages resources only from
`macos-native/HelperResources`.

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

Sparkle verifies the
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

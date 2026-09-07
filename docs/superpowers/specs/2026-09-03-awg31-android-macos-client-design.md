# VEX Android and macOS AmneziaWG 3.1 Client Support Design

**Date:** 2026-09-03  
**Linear:** IBO-119  
**Repository:** standalone `ibotpafos/vex-client`  
**Status:** Approved design, pending implementation plan

## Objective

Add first-party AmneziaWG 3.1 support to the VEX Android and native macOS
clients without breaking existing AmneziaWG 3.0 profiles. Both clients must
consume the same AWG 3.1 feature profiles already published by VEX, apply every
supported field to the native engine, establish a tunnel, and exchange traffic.

This work changes client source and build inputs only. It does not publish an
APK, PKG, Sparkle update, website download, or production rollout.

## Current State

The clients pin `amneziawg-go v3.0.20260805` at commit
`08d68cdae27762c3e07f36bbb12d2bad32f81926`. Android uses the official
`amneziawg-android` tunnel module with a locally pinned Go engine. Native macOS
bundles universal `arm64 + x86_64` `amneziawg-go` and `awg` binaries inside the
application and installs them through the privileged helper flow.

The application-level profile models already carry the original AWG 3 fields,
including `HeaderProtectionKey` and `I1`. The missing contract is a qualified,
reproducibly pinned 3.1 engine/toolchain and complete end-to-end proof that the
new parameter set reaches that engine on both platforms.

## Selected Approach

Upgrade both clients to the same official 3.1 engine generation used by the VEX
feature servers. Keep one engine per platform rather than shipping parallel 3.0
and 3.1 engines. The 3.1 engine remains responsible for accepting older 3.0
profiles.

Pinned upstream inputs:

| Component | Ref | Purpose |
| --- | --- | --- |
| `amneziawg-go` | `b5928efb6ca19f0153958460c3d141f04abc5c2e` (`v3.1.20260828`) | Android and macOS data plane |
| `amneziawg-tools` | `ee0f0a9aa34ff0a0da4b3433b9512781cfe02843` (`v3.1.20260812`) | macOS `awg` control tool |
| `amneziawg-android` | `5c16489e2cd9ed3a0a7a27c7445bba5238132f86` (`v3.1.20260814`) | Android tunnel wrapper |

Refs are constants in repository scripts and tests. Environment overrides may
redirect repository URLs for controlled mirrors, but production refs must not be
runtime-selectable.

## Architecture

### Shared upstream contract

The upstream contract test becomes the single source of truth for the three
refs and version labels. Android and macOS bootstrap/build scripts must read or
assert the same constants. A checkout at a different commit fails before native
compilation.

The existing upstream integrity verifier remains enabled. Any VEX-specific
patch must be explicit, deterministic, idempotent, covered by a source-shape
test, and limited to integration concerns. VEX must not maintain a private
protocol fork.

### Android

The Android bootstrap flow checks out the pinned 3.1 Android wrapper and the
pinned 3.1 Go engine, initializes required submodules, and applies only the
existing VEX integration patches after proving that they still apply cleanly.
Gradle continues to consume `:amneziawg-tunnel` from the external checkout.

The Android configuration boundary must preserve all recognized 3.0 and 3.1
interface fields and deliver them to the native backend without renaming,
dropping, or inventing defaults. The APK verification gate must prove that the
packaged native libraries came from the pinned checkout and contain all expected
ABIs.

### Native macOS

The macOS bootstrap flow checks out the pinned 3.1 Go and tools commits. The
binary builder produces universal `arm64 + x86_64` binaries for both
`amneziawg-go` and `awg`, validates their reported versions and architectures,
and installs them into `macos-native/HelperResources`.

The existing helper-resource digest comparison remains the replacement trigger:
an installed 3.0 helper is replaced when the application bundles the 3.1
resources. Profile files, application credentials, and unrelated tunnel state
must not be deleted during the helper upgrade.

Mach-O architecture inspection runs in build/preflight code, not in a
PackageKit postinstall sandbox.

## Configuration Contract

Both clients must preserve and apply the following fields when supplied by the
VEX profile:

- existing AWG values: `Jc`, `Jmin`, `Jmax`, `S1`-`S4`, `H1`-`H4`;
- signature chains: `I1`-`I5`;
- `HeaderProtectionKey`;
- content-padding minimum and maximum;
- rekey-after-time minimum and maximum;
- reject-after-time minimum and maximum;
- keepalive minimum and maximum;
- maximum handshake-attempt minimum and maximum;
- `RandomTrailers` and `DisableCookies` when present.

Values must retain their server-provided representation until the platform's
official parser converts them. Secrets and key material must never be printed in
logs, test output, build metadata, or error telemetry.

Older 3.0 profiles that omit the new 3.1-only values remain valid. Missing
optional 3.1 values select official engine behavior; the client must not synthesize
its own protocol defaults.

## Validation and Failure Handling

Configuration validation happens before tunnel activation. A malformed key,
invalid range, unsupported critical field, or parser rejection returns a stable
client error and leaves the previous tunnel state unchanged. The client must not
silently remove a rejected field and retry with a weakened profile.

Network recovery may switch only among endpoints explicitly supplied for the
same AWG generation. AWG 3.1 must never fall back to the retired AWG 2 listener.
Normal reconnect, sleep/wake, and network-path changes reuse the complete profile
instead of reconstructing a reduced subset.

## Test Strategy

### Static and unit checks

- upstream ref/version contract for Android, Go, and tools;
- clean and repeatable bootstrap with patch idempotency;
- parser fixtures for complete 3.1, minimal 3.0, malformed ranges, malformed
  header keys, and unknown critical fields;
- Android unit tests proving recovery preserves the full profile;
- macOS model/render tests proving every field is emitted exactly once;
- log-redaction assertions for private, preshared, and header-protection keys.

### Build checks

- Android Gradle unit tests and release-variant compile;
- APK/AAB inspection for required ABIs and pinned native engine identity;
- native macOS Swift tests and release build;
- `lipo` verification that bundled `awg`, `amneziawg-go`, and helper binaries
  contain `arm64` and `x86_64`;
- helper-resource digest and version replacement probes;
- code-signature verification for locally built application resources.

### Runtime matrix

Each platform must exercise:

1. existing AWG 3.0 profile;
2. AWG 3.1 compatibility profile;
3. AWG 3.1 Features profile with the complete field set;
4. fresh connect and reconnect;
5. network-path change;
6. sleep/wake where the platform supports it;
7. rollback to the previous client build without losing the saved profile.

Acceptance requires a fresh server-observed handshake, bidirectional byte
counters, and application traffic through the feature endpoint. A successful
build, parsed configuration, or healthy server alone is insufficient.

Runtime tests must not interrupt an unrelated active VPN. macOS connect,
disconnect, route, DNS, and Packet Filter checks run only on a disposable host or
an explicitly inactive baseline. Android physical testing uses a dedicated
emulator/device fixture.

## Delivery Sequence

1. Update and lock upstream inputs with red/green contract tests.
2. Qualify Android bootstrap, parser path, native build, and emulator/device
   runtime.
3. Qualify macOS universal binaries, helper replacement, parser/render path, and
   disposable-host runtime.
4. Run the cross-platform 3.0/3.1 compatibility matrix.
5. Commit and push the client branch and attach evidence to IBO-119.
6. Build signed release candidates in the normal release lane.
7. Publish only after signing, notarization where applicable, staged canary, and
   rollback verification.

Android and macOS may be implemented in separate commits, but neither is called
complete until both pass the shared runtime contract.

## Rollback

Source rollback restores the previous pinned refs and bootstrap/build scripts.
Client rollback installs the previous signed build while retaining the saved
profile and credentials. Server AWG 3.0 locations remain available during the
client canary so a previous client build has a compatible target.

If 3.1 runtime qualification fails, distribution remains on the previous client
build. No server profile or customer device is rewritten merely to make a failed
client candidate connect.

## Acceptance Criteria

- Android and macOS artifacts contain the pinned official 3.1 engine inputs.
- Complete AWG 3.1 Features profiles reach the engine without field loss.
- Existing AWG 3.0 profiles still connect.
- Both platforms demonstrate fresh handshake, RX/TX growth, reconnect, and
  network-path recovery against a VEX 3.1 feature node.
- Malformed or unsupported profiles fail closed without damaging the prior
  connection state.
- No secret value appears in source, artifacts, logs, Linear, or test reports.
- Rollback restores the previous client behavior and preserves user data.
- Release publication remains blocked until signing and physical runtime gates
  pass.

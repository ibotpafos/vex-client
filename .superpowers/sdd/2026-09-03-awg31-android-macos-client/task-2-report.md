# Task 2 report — Android AWG 3.1 parser and recovery compatibility

## Commit

`071d756 test(android): enforce AWG 3.1 profile compatibility`

## Changed files

- `android/app/src/test/java/com/vexguard/app/vpn/Awg31ConfigCompatibilityTest.kt` (new)
- `android/app/src/test/java/com/vexguard/app/vpn/VpnNetworkRecoveryTest.kt`

The new parser suite uses deterministic Base64 encodings of fixed 32-byte arrays. The brief's literal B/C synthetic values were rejected by the official key decoder, so the brief-approved replacement was applied; no real key material is present.

## Coverage implemented

- Complete AWG 3.1 `Config.parse(InputStream)` → `toAwgQuickString()` round trip checks `HeaderProtectionKey`, every supplied 3.1 range/string field, `RandomTrailers`, and `DisableCookies`.
- Legacy AWG 3.0 profile parses while omitting the two 3.1-only flags.
- Official parser rejects malformed `HeaderProtectionKey` with `INVALID_KEY`/`HEADER_PROTECTION_KEY` and rejects an unknown critical interface attribute with `UNKNOWN_ATTRIBUTE`/`INTERFACE`.
- Official parser **accepts and preserves** malformed textual range syntax for `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, and `MaxHandshakeAttempts`. The upstream `Interface` parser stores these fields as trimmed strings without range validation. This is recorded as observed upstream behavior, not client behavior invented by this task.
- `Config.toString()` does not expose either synthetic private or header-protection key.
- Recovery candidates retain each AWG 3.1 fixture field, normalize-identically outside their `Endpoint` line, and never contain `:51820`.

## Dependencies and pinned identity

Bootstrap command (exit `0`):

```bash
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
bash scripts/bootstrap_amneziawg_android.sh
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android" rev-parse HEAD
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-go" rev-parse HEAD
```

Observed output:

```text
5c16489e2cd9ed3a0a7a27c7445bba5238132f86
b5928efb6ca19f0153958460c3d141f04abc5c2e
```

Installed the missing local build dependencies in disposable workspace locations: `npm ci --ignore-scripts`, Android SDK platform/build-tools 36.0.0, and required NDKs under `.local/android-sdk`; Homebrew OpenJDK 17 was already installed and was selected through `JAVA_HOME`.

## Honest TDD evidence

The pre-Task-1 wrapper state was unavailable by the task's sequential-execution ruling, so no fabricated 3.0-wrapper RED result is recorded.

First focused execution after adding the test reached the pinned 3.1 official parser but exited nonzero because the brief's literal synthetic B/C key strings failed upstream `Key.fromBase64` validation. The resulting JUnit report contained 6 tests, 3 failures, 0 errors; each failure was `BadConfigException: KeyFormatException`. That genuine test-fixture failure was corrected only by replacing all test keys with fixed 32-byte Base64 encodings, as the brief directs.

The final focused command (exit `0`):

```bash
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$PWD/.local/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
export AMNEZIAWG_TUNNEL_DIR="$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android/tunnel"
(cd android && ./gradlew :app:testReleaseUnitTest --tests 'com.vexguard.app.vpn.Awg31ConfigCompatibilityTest')
```

Literal result: `BUILD SUCCESSFUL in 5s`; final XML reports `tests="6" skipped="0" failures="0" errors="0"`.

## Verification

Full release unit suite command (exit `0`):

```bash
(cd android && ./gradlew :app:testReleaseUnitTest)
```

Literal result: `BUILD SUCCESSFUL in 4s`; final report aggregate: 5 XML suites, `tests=26 failures=0 errors=0`.

Release compile command (exit `0`):

```bash
(cd android && ./gradlew :app:compileReleaseKotlin)
```

Literal result: `BUILD SUCCESSFUL in 4s`.

Requested release assembly command (exit `1`):

```bash
(cd android && ./gradlew :app:assembleRelease)
```

Literal result:

```text
Release build requires VEX_UPLOAD_STORE_FILE, VEX_UPLOAD_STORE_PASSWORD, VEX_UPLOAD_KEY_ALIAS, and VEX_UPLOAD_KEY_PASSWORD.
```

The build script enforces this at `android/app/build.gradle:334`; no signing values were used. Consequently no release APK was emitted under `android/app/build/outputs/apk/release/`, so the requested `unzip -Z1` packaged-ABI inspection could not run. The pinned wrapper compile did include `:amneziawg-tunnel` release tasks, and its checked-out identities are listed above; packaged ABI presence remains an unsigned-release/signing gate.

`git diff --check` exited `0` before commit.

## Codebase-memory evidence

- Confirmed index project `Volumes-D-Projects-vpn-main`, generation `2026-09-03T14:44:23Z`, status `ready`.
- `search_graph` queries for `VpnNetworkRecovery` and `configCandidates` returned zero nodes because this linked worktree's Android paths are absent from that index root.
- `check_index_coverage` for `android/app/src/main/java/com/vexguard/app/vpn/VpnNetworkRecovery.kt`, `VpnNetworkRecoveryTest.kt`, and the new `Awg31ConfigCompatibilityTest.kt` returned `no_recorded_issue` but `freshness: missing` with recommended action `read_source_and_reindex`.
- Per that result, direct source inspection was used for `VpnNetworkRecovery.kt`, both test files, `android/app/build.gradle`, and the pinned upstream parser under `.local/awg31-android/amneziawg-android/tunnel`.

## Self-review

Reviewed the final diff and test XML. The recovery assertion compares each entire candidate after replacing the one endpoint line, so preservation is stronger than substring-only checks. Parser negative assertions target official `BadConfigException` reason/location values. No production source, deployment, publishing, or secrets changed.

## Concerns / remaining gate

The official parser does not validate malformed AWG 3.1 range strings; the passing compatibility test documents that exact upstream behavior. A signed release APK and its ABI listing require the existing release-signing environment and were not produced in this task.

## Fix round 1/5 — fail-closed activation, explicit-only recovery, and error redaction

This section supersedes the original task's conclusions about malformed range acceptance and synthesized recovery ports.

### Production changes

- Added `AwgConfigSafety.parseForActivation`: it accepts only decimal non-negative integers or ascending integer ranges for `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, and `MaxHandshakeAttempts`; it rejects descending, negative, nonnumeric, partially empty, multi-dash, and other malformed forms before the official parser is invoked. Missing optional fields are untouched.
- `WireGuardController.connect` now parses through that seam before stopping the anti-leak blocker or calling `backend.setState`; `AwgConfigValidationException` is rethrown without the generic teardown path, preserving an already-UP tunnel on invalid replacement input. Recovery parses through the same seam.
- `VpnNetworkRecovery.configCandidates` now returns exactly the supplied profile. It does not synthesize `51821`, `443`, `51820`, or any other endpoint/port; an alternate endpoint requires a future explicit-profile contract.
- Inspected the actual module error path: `VexVpnModule.rejectVpnError` had passed the raw exception and raw message to `Log.e`, Bugsink/Sentry, and React Native. `VpnLogRedaction` now redacts `PrivateKey`, `PresharedKey`, and `HeaderProtectionKey` assignments and replaces the captured/rejected throwable with one containing only that sanitized message. Endpoint and other useful non-secret error content remain available.
- The compatibility test uses exact normalized `toAwgQuickString()` equality for the complete 3.1 and legacy 3.0 fixtures, covering every supplied recognized interface and peer field. It also covers valid singleton/range syntax, all malformed values across all six fields, logging/telemetry redaction, and unchanged explicit recovery endpoints including IPv6.

### Genuine RED evidence

After adding the range-rejection test but before introducing the production validation seam, the focused command exited `1`:

```bash
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$PWD/.local/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
export AMNEZIAWG_TUNNEL_DIR="$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android/tunnel"
(cd android && ./gradlew :app:testReleaseUnitTest --tests 'com.vexguard.app.vpn.Awg31ConfigCompatibilityTest' --tests 'com.vexguard.app.vpn.VpnNetworkRecoveryTest')
```

Literal result:

```text
> Task :app:compileReleaseUnitTestKotlin FAILED
Awg31ConfigCompatibilityTest.kt:115:11 Unresolved reference 'AwgConfigSafety'.
BUILD FAILED in 4s
```

This was a genuine new-test RED before the intended production seam existed; it is not presented as a pre-3.1-wrapper result. A subsequent redaction-focused run also genuinely failed at `Awg31ConfigCompatibilityTest.kt:208` until the replacement string was corrected to preserve regex capture group 1.

### GREEN verification

Focused command (exit `0`):

```bash
(cd android && ./gradlew :app:testReleaseUnitTest --tests 'com.vexguard.app.vpn.Awg31ConfigCompatibilityTest' --tests 'com.vexguard.app.vpn.VpnNetworkRecoveryTest')
```

Literal result: `BUILD SUCCESSFUL in 4s`. The two focused XML suites report 15 tests, 0 failures, 0 errors.

Full release unit suite command (exit `0`):

```bash
(cd android && ./gradlew :app:testReleaseUnitTest)
```

Literal result: `BUILD SUCCESSFUL in 3s`. Final XML aggregate: 5 suites, `tests=27 failures=0 errors=0 skipped=0`.

Release compile command (exit `0`):

```bash
(cd android && ./gradlew :app:compileReleaseKotlin)
```

Literal result: `BUILD SUCCESSFUL in 2s` (`369 actionable tasks: 2 executed, 367 up-to-date`).

Diff check command (exit `0`):

```bash
git diff --check
```

Literal result: no output; `git-diff-check-exit=0`.

### Codebase-memory and source evidence

The existing index remains `Volumes-D-Projects-vpn-main`, generation `2026-09-03T14:44:23Z`. `check_index_coverage` was run for all seven changed Android paths: `AwgConfigSafety.kt`, `VpnLogRedaction.kt`, `WireGuardController.kt`, `VpnNetworkRecovery.kt`, `VexVpnModule.kt`, `Awg31ConfigCompatibilityTest.kt`, and `VpnNetworkRecoveryTest.kt`. Each returned `status: no_recorded_issue` but `freshness: missing` and `recommended_action: read_source_and_reindex`; direct source review was therefore used for those files and for the upstream serializer/parser ordering.

### Cleanup, self-review, and remaining gate

Removed only this task's disposable dependency directory with a path-asserted Python `shutil.rmtree` command:

```text
removed /Volumes/D/Projects/mobile-worktrees/ibo-119-awg31-client-support-20260903/.local
exists=False
```

Self-review inspected the production/test diff and XML reports. The validation seam runs before `setState` and before anti-leak stopping; validation failures take a dedicated no-teardown catch. Recovery leaves all bytes unchanged, so it cannot mutate an endpoint or introduce `51820`. Error reporting sends a sanitized throwable to both Android logging and Sentry while retaining non-secret error context.

The remaining release gate is unchanged: the signed APK/ABI check needs the existing `VEX_UPLOAD_STORE_FILE`, `VEX_UPLOAD_STORE_PASSWORD`, `VEX_UPLOAD_KEY_ALIAS`, and `VEX_UPLOAD_KEY_PASSWORD`; none were supplied or used.

### Changed files and commit

Implementation commit: `9bffa1fe43f615521b4db134f20ee47da92e3d44` (`fix(android): fail closed on unsafe AWG configs`).

- `android/app/src/main/java/com/vexguard/app/vpn/AwgConfigSafety.kt`
- `android/app/src/main/java/com/vexguard/app/vpn/VpnLogRedaction.kt`
- `android/app/src/main/java/com/vexguard/app/vpn/VexVpnModule.kt`
- `android/app/src/main/java/com/vexguard/app/vpn/VpnNetworkRecovery.kt`
- `android/app/src/main/java/com/vexguard/app/vpn/WireGuardController.kt`
- `android/app/src/test/java/com/vexguard/app/vpn/Awg31ConfigCompatibilityTest.kt`
- `android/app/src/test/java/com/vexguard/app/vpn/VpnNetworkRecoveryTest.kt`
- `.superpowers/sdd/2026-09-03-awg31-android-macos-client/task-2-report.md` (this appended evidence)

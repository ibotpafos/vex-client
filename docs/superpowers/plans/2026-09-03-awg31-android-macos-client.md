# VEX Android and macOS AmneziaWG 3.1 Client Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship testable Android and native macOS client candidates that run the pinned official AmneziaWG 3.1 engine, preserve complete 3.1 profiles, and remain compatible with existing AWG 3.0 profiles.

**Architecture:** Pin one official 3.1 engine generation across Android and macOS, keep platform-native parsers/build pipelines, and verify the profile at the parser, packaged-artifact, and live-tunnel boundaries. Android consumes the official tunnel module with the pinned Go engine; macOS bundles universal Go/tools binaries and upgrades them through the existing helper digest/version contract.

**Tech Stack:** Kotlin/JUnit/Gradle, Swift/SwiftPM, Bash, Node.js contract tests, Go-based AmneziaWG userspace engine, Android Emulator/ADB, macOS universal Mach-O tooling.

**Spec:** `docs/superpowers/specs/2026-09-03-awg31-android-macos-client-design.md`

## Global Constraints

- Work only in `/Volumes/D/Projects/mobile-worktrees/ibo-119-awg31-client-support-20260903` on `codex/ibo-119-awg31-client-support`; do not modify the dirty primary checkout.
- Pin `amneziawg-go` to `b5928efb6ca19f0153958460c3d141f04abc5c2e` (`v3.1.20260828`).
- Pin `amneziawg-tools` to `ee0f0a9aa34ff0a0da4b3433b9512781cfe02843` (`v3.1.20260812`).
- Pin `amneziawg-android` to `5c16489e2cd9ed3a0a7a27c7445bba5238132f86` (`v3.1.20260814`).
- Leave the iOS `amneziawg-apple v3.0.1` and Go `v3.0.20260805` pins unchanged; iOS is outside this implementation.
- Do not add runtime-selectable production refs or a private protocol fork.
- Do not log private keys, preshared keys, header-protection keys, subscription bodies, or raw production configurations.
- Existing AWG 3.0 profiles must remain parseable and connectable through the 3.1 engine.
- Unknown or malformed critical configuration must fail before tunnel activation; never retry after silently dropping fields.
- Do not publish APK/PKG/Sparkle/website artifacts from this plan.
- Do not alter a host's active VPN, routes, DNS, or Packet Filter state outside a dedicated fixture.

## File Map

- `tests/amneziawg-upstream-contract.mjs`: authoritative upstream ref/version and bootstrap-source contract.
- `scripts/bootstrap_amneziawg_android.sh`: deterministic Android wrapper and Go-engine checkout plus VEX integration patches.
- `scripts/bootstrap_amneziawg_macos.sh`: deterministic macOS Go/tools checkout.
- `scripts/build_amneziawg_macos_binaries.sh`: universal 3.1 binary build and version/architecture verification.
- `android/app/src/test/java/com/vexguard/app/vpn/Awg31ConfigCompatibilityTest.kt`: Android official-parser 3.0/3.1 round-trip contract.
- `android/app/src/test/java/com/vexguard/app/vpn/VpnNetworkRecoveryTest.kt`: recovery candidates preserve every interface field.
- `macos-native/Sources/VEXNativeMac/Models/VEXModels.swift`: managed-profile DTO fields for the 3.1 contract.
- `macos-native/Sources/VEXNativeMac/Services/VPNProfileService.swift`: deterministic macOS config rendering.
- `macos-native/Tests/VEXNativeMacTests/NativeParityModelTests.swift`: decode/render/helper-version contracts.
- `macos-native/HelperResources/helper-version`: helper-resource replacement generation.
- `docs/verification/2026-09-03-awg31-client-matrix.md`: sanitized build/runtime results and unresolved release gates.

---

### Task 1: Pin the shared official 3.1 upstream generation

**Files:**
- Modify: `tests/amneziawg-upstream-contract.mjs:7-35`
- Modify: `scripts/bootstrap_amneziawg_android.sh:7-61`
- Modify: `scripts/bootstrap_amneziawg_macos.sh:6-46`
- Modify: `scripts/build_amneziawg_macos_binaries.sh:4-75`

**Interfaces:**
- Consumes: official immutable Git commits listed in Global Constraints.
- Produces: deterministic `amneziawg-go`, `amneziawg-tools`, and `amneziawg-android` checkouts used by Tasks 2-4.

- [ ] **Step 1: Change the upstream contract first so it fails on the current 3.0 pins**

Replace the shared constants and assertions with explicit platform pins while retaining the iOS 3.0 contract:

```js
const awg31GoRef = 'b5928efb6ca19f0153958460c3d141f04abc5c2e';
const awg31GoVersion = 'v3.1.20260828';
const awg31ToolsRef = 'ee0f0a9aa34ff0a0da4b3433b9512781cfe02843';
const awg31AndroidRef = '5c16489e2cd9ed3a0a7a27c7445bba5238132f86';
const iosGoVersion = 'v3.0.20260805';

assert.ok(android.includes(`android_ref="${awg31AndroidRef}"`));
assert.ok(android.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macos.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macos.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(macosBuild.includes(`go_ref="${awg31GoRef}"`));
assert.ok(macosBuild.includes(`tools_ref="${awg31ToolsRef}"`));
assert.ok(macosBuild.includes('AmneziaWG 3.1'));
assert.ok(ios.includes(`go_version="${iosGoVersion}"`));
assert.ok(!android.includes('AMNEZIAWG_GO_REF'));
assert.ok(!macos.includes('AMNEZIAWG_GO_REF'));
```

- [ ] **Step 2: Run the contract and verify the red state**

Run:

```bash
node tests/amneziawg-upstream-contract.mjs
```

Expected: non-zero exit at the first Android or macOS 3.1 ref assertion because the scripts still contain the 3.0 refs.

- [ ] **Step 3: Update the Android bootstrap pins**

Set only immutable constants:

```bash
android_ref="5c16489e2cd9ed3a0a7a27c7445bba5238132f86"
go_ref="b5928efb6ca19f0153958460c3d141f04abc5c2e"
```

Keep `clone_or_reset`, recursive submodule initialization, the local-Go patch, foreground-service patch, and upstream integrity verification unchanged. Run both patch paths with `git apply --check` before accepting them.

- [ ] **Step 4: Update the macOS bootstrap and builder pins**

Set these constants in both macOS scripts:

```bash
go_ref="b5928efb6ca19f0153958460c3d141f04abc5c2e"
tools_ref="ee0f0a9aa34ff0a0da4b3433b9512781cfe02843"
```

Change human-readable build labels from `3.0` to the exact 3.1 versions, but do not change binary names or install locations.

- [ ] **Step 5: Run the green source contract**

Run:

```bash
node tests/amneziawg-upstream-contract.mjs
```

Expected: `AmneziaWG upstream contract OK`, exit 0.

- [ ] **Step 6: Bootstrap both platform dependency trees in disposable external directories**

Run:

```bash
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
bash scripts/bootstrap_amneziawg_android.sh
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android" rev-parse HEAD
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-go" rev-parse HEAD

export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-macos"
bash scripts/bootstrap_amneziawg_macos.sh
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-go" rev-parse HEAD
git -C "$AMNEZIAWG_EXTERNAL_DIR/amneziawg-tools" rev-parse HEAD
```

Expected: the four printed SHAs equal the Global Constraints; both bootstrap commands exit 0 without uncommitted changes in the client repository.

- [ ] **Step 7: Commit the shared upstream contract**

```bash
git add tests/amneziawg-upstream-contract.mjs \
  scripts/bootstrap_amneziawg_android.sh \
  scripts/bootstrap_amneziawg_macos.sh \
  scripts/build_amneziawg_macos_binaries.sh
git commit -m "build(awg31): pin Android and macOS engines"
```

---

### Task 2: Prove Android parses and preserves AWG 3.1 profiles

**Files:**
- Create: `android/app/src/test/java/com/vexguard/app/vpn/Awg31ConfigCompatibilityTest.kt`
- Modify: `android/app/src/test/java/com/vexguard/app/vpn/VpnNetworkRecoveryTest.kt:47-98`

**Interfaces:**
- Consumes: `org.amnezia.awg.config.Config.parse(InputStream)` and `Config.toAwgQuickString()` from Task 1's pinned Android wrapper.
- Produces: executable proof that VEX passes complete 3.1 and legacy 3.0 profiles through the official parser without field loss.

- [ ] **Step 1: Add a complete 3.1 parser round-trip test**

Create the following test fixture, using synthetic keys only:

```kotlin
package com.vexguard.app.vpn

import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import org.amnezia.awg.config.Config
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Awg31ConfigCompatibilityTest {
  private val privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  private val publicKey = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  private val headerKey = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="

  @Test
  fun roundTripsCompleteAwg31Interface() {
    val source = """
      [Interface]
      PrivateKey = $privateKey
      Address = 10.64.249.2/32
      Jc = 6
      Jmin = 10
      Jmax = 50
      S1 = 12
      S2 = 12
      S3 = 12
      S4 = 12
      H1 = 1000001-1000099
      H2 = 2000001-2000099
      H3 = 3000001-3000099
      H4 = 4000001-4000099
      I1 = <r 8><t><rc 8>
      HeaderProtectionKey = $headerKey
      ContentPaddingAddition = 10-40
      RekeyAfterTime = 120-180
      RekeyTimeout = 2-4
      RejectAfterTime = 180-240
      KeepaliveTimeout = 10-15
      MaxHandshakeAttempts = 10-15
      RandomTrailers = true
      DisableCookies = false

      [Peer]
      PublicKey = $publicKey
      Endpoint = 192.0.2.1:51824
      AllowedIPs = 0.0.0.0/0
    """.trimIndent()

    val parsed = Config.parse(ByteArrayInputStream(source.toByteArray(StandardCharsets.UTF_8)))
    val rendered = parsed.toAwgQuickString()
    listOf(
      "HeaderProtectionKey = $headerKey",
      "ContentPaddingAddition = 10-40",
      "RekeyAfterTime = 120-180",
      "RekeyTimeout = 2-4",
      "RejectAfterTime = 180-240",
      "KeepaliveTimeout = 10-15",
      "MaxHandshakeAttempts = 10-15",
      "RandomTrailers = true",
      "DisableCookies = false",
    ).forEach { assertTrue("missing $it", rendered.contains(it)) }
    assertTrue(rendered.contains("PrivateKey = $privateKey\n"))
  }

  @Test
  fun acceptsLegacyAwg30WithoutAwg31OnlyFlags() {
    val source = "[Interface]\nPrivateKey = $privateKey\nAddress = 10.64.252.2/32\nJc = 4\nS1 = 12\nS2 = 12\nS3 = 12\nS4 = 12\nHeaderProtectionKey = $headerKey\n\n[Peer]\nPublicKey = $publicKey\nEndpoint = 192.0.2.1:443\nAllowedIPs = 0.0.0.0/0\n"
    val rendered = Config.parse(ByteArrayInputStream(source.toByteArray())).toAwgQuickString()
    assertTrue(rendered.contains("HeaderProtectionKey = $headerKey"))
    assertFalse(rendered.contains("RandomTrailers"))
    assertFalse(rendered.contains("DisableCookies"))
  }
}
```

If the synthetic B/C keys are rejected by the official key decoder, replace them with `base64.StdEncoding` output for fixed 32-byte arrays generated inside the test; do not copy any real key.

- [ ] **Step 2: Run the Android test and verify it is red before bootstrap/build wiring is complete**

Run:

```bash
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
export AMNEZIAWG_TUNNEL_DIR="$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android/tunnel"
(cd android && ./gradlew :app:testReleaseUnitTest --tests 'com.vexguard.app.vpn.Awg31ConfigCompatibilityTest')
```

Expected before Task 1's 3.1 wrapper is active: compile failure for 3.1-only parser members or a parser failure on `RandomTrailers`/`DisableCookies`.

- [ ] **Step 3: Add recovery preservation coverage**

Add a test that builds a config containing `I1`, `HeaderProtectionKey`, `ContentPaddingAddition`, `RandomTrailers`, and `DisableCookies`, calls `VpnNetworkRecovery.configCandidates`, and asserts every candidate differs only in its `Endpoint` line:

```kotlin
@Test
fun preservesEveryAwg31FieldAcrossRecoveryCandidates() {
  val config = "[Interface]\nI1 = <r 8><t><rc 8>\nHeaderProtectionKey = synthetic\nContentPaddingAddition = 10-40\nRandomTrailers = true\nDisableCookies = false\n[Peer]\nEndpoint = de.example.test:51824"
  val candidates = VpnNetworkRecovery.configCandidates(config)
  candidates.forEach { candidate ->
    assertTrue(candidate.contains("I1 = <r 8><t><rc 8>"))
    assertTrue(candidate.contains("HeaderProtectionKey = synthetic"))
    assertTrue(candidate.contains("ContentPaddingAddition = 10-40"))
    assertTrue(candidate.contains("RandomTrailers = true"))
    assertTrue(candidate.contains("DisableCookies = false"))
    assertFalse(candidate.contains(":51820"))
  }
}
```

- [ ] **Step 4: Run Android unit tests and release compile**

Run:

```bash
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-android"
export AMNEZIAWG_TUNNEL_DIR="$AMNEZIAWG_EXTERNAL_DIR/amneziawg-android/tunnel"
(cd android && ./gradlew :app:testReleaseUnitTest)
(cd android && ./gradlew :app:assembleRelease)
```

Expected: both commands exit 0; release APKs exist under `android/app/build/outputs/apk/release/`.

- [ ] **Step 5: Inspect packaged Android ABIs without exposing configuration**

Run:

```bash
apk="$(find android/app/build/outputs/apk/release -name '*.apk' -type f | head -1)"
unzip -Z1 "$apk" | grep -E '^lib/(arm64-v8a|armeabi-v7a|x86_64)/libwg-go\.so$' | sort
```

Expected: the required production ABIs from the Gradle configuration are present exactly once and no unexpected legacy AWG library is packaged.

- [ ] **Step 6: Commit Android compatibility coverage**

```bash
git add android/app/src/test/java/com/vexguard/app/vpn/Awg31ConfigCompatibilityTest.kt \
  android/app/src/test/java/com/vexguard/app/vpn/VpnNetworkRecoveryTest.kt
git commit -m "test(android): enforce AWG 3.1 profile compatibility"
```

---

### Task 3: Extend the native macOS managed-profile contract

**Files:**
- Modify: `macos-native/Sources/VEXNativeMac/Models/VEXModels.swift:496-531`
- Modify: `macos-native/Sources/VEXNativeMac/Services/VPNProfileService.swift:400-427`
- Modify: `macos-native/Tests/VEXNativeMacTests/NativeParityModelTests.swift:66-99`

**Interfaces:**
- Consumes: managed VPN JSON keys supplied by the VEX API.
- Produces: `VPNProfileService.amneziaConfig(_:) -> String` containing each supplied 3.1 field exactly once.

- [ ] **Step 1: Extend the failing macOS decode/render test**

Add these JSON fields to `testManagedProfilePreservesAWG3Contract`:

```json
"i1": "<r 8><t><rc 8>",
"random_trailers": "true",
"disable_cookies": "false"
```

Add exact assertions:

```swift
XCTAssertTrue(config.contains("I1 = <r 8><t><rc 8>\n"))
XCTAssertTrue(config.contains("RandomTrailers = true\n"))
XCTAssertTrue(config.contains("DisableCookies = false\n"))
XCTAssertEqual(config.components(separatedBy: "HeaderProtectionKey =").count - 1, 1)
```

- [ ] **Step 2: Run the focused Swift test and verify the red state**

Run:

```bash
(cd macos-native && swift test --filter NativeParityModelTests/testManagedProfilePreservesAWG3Contract)
```

Expected: decode/render assertions fail because `randomTrailers` and `disableCookies` do not exist yet.

- [ ] **Step 3: Add the two managed-profile properties**

In `ManagedVpnAmnezia`, add:

```swift
var randomTrailers: String?
var disableCookies: String?
```

and coding keys:

```swift
case randomTrailers = "random_trailers"
case disableCookies = "disable_cookies"
```

Strings intentionally preserve the official parser representation instead of inventing client-side Boolean normalization.

- [ ] **Step 4: Render the fields in deterministic interface order**

Append after `MaxHandshakeAttempts`:

```swift
addString("RandomTrailers", amnezia.randomTrailers, to: &lines)
addString("DisableCookies", amnezia.disableCookies, to: &lines)
```

Do not alter `sanitizedMacOSHelperConfig`; it already transforms only routing and endpoint lines.

- [ ] **Step 5: Run focused and full macOS tests**

Run:

```bash
(cd macos-native && swift test --filter NativeParityModelTests/testManagedProfilePreservesAWG3Contract)
(cd macos-native && swift test)
```

Expected: all tests pass with zero secret values printed.

- [ ] **Step 6: Commit the macOS profile contract**

```bash
git add macos-native/Sources/VEXNativeMac/Models/VEXModels.swift \
  macos-native/Sources/VEXNativeMac/Services/VPNProfileService.swift \
  macos-native/Tests/VEXNativeMacTests/NativeParityModelTests.swift
git commit -m "feat(macos): preserve AWG 3.1 profile fields"
```

---

### Task 4: Build and package the macOS 3.1 helper generation

**Files:**
- Modify: `macos-native/HelperResources/helper-version`
- Modify: `macos-native/Tests/VEXNativeMacTests/NativeParityModelTests.swift:887-923`
- Verify generated resources: `macos-native/HelperResources/awg`
- Verify generated resources: `macos-native/HelperResources/amneziawg-go`

**Interfaces:**
- Consumes: Task 1's pinned macOS Go/tools checkout and Task 3's complete config renderer.
- Produces: helper generation `37` with universal 3.1 `awg` and `amneziawg-go` resources.

- [ ] **Step 1: Make the helper-generation contract fail**

Change the existing assertion to:

```swift
XCTAssertEqual(helperVersion, "37")
```

- [ ] **Step 2: Run the focused helper contract and verify red**

Run:

```bash
(cd macos-native && swift test --filter NativeParityModelTests/testNativeBuildUsesVersionedHelperResources)
```

Expected: failure showing current helper version `36` versus expected `37`.

- [ ] **Step 3: Bump the helper generation**

Write exactly `37` plus a trailing newline to `macos-native/HelperResources/helper-version`.

- [ ] **Step 4: Build universal pinned 3.1 resources**

Run:

```bash
export AMNEZIAWG_EXTERNAL_DIR="$PWD/.local/awg31-macos"
bash scripts/build_amneziawg_macos_binaries.sh --skip-bootstrap
```

Expected output includes the pinned 3.1 tool versions and reports `arm64 x86_64` for both binaries.

- [ ] **Step 5: Verify architectures, hashes, and focused tests**

Run:

```bash
lipo -archs macos-native/HelperResources/awg
lipo -archs macos-native/HelperResources/amneziawg-go
shasum -a 256 macos-native/HelperResources/awg macos-native/HelperResources/amneziawg-go
(cd macos-native && swift test --filter NativeParityModelTests/testNativeBuildUsesVersionedHelperResources)
(cd macos-native && swift test)
```

Expected: both architecture commands print `x86_64 arm64` or `arm64 x86_64`; hashes are recorded only in local verification evidence; all Swift tests pass.

- [ ] **Step 6: Build and inspect the unsigned local app candidate**

Run:

```bash
bash scripts/build_native_macos_app.sh
app="macos-native/build/VEX Native.app"
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/Resources/resources/awg"
lipo -archs "$app/Contents/Resources/resources/amneziawg-go"
```

Expected: app build and strict code verification exit 0; both bundled resources remain universal. This is local build evidence, not notarization or public-release acceptance.

- [ ] **Step 7: Commit macOS helper generation and reproducible resources**

Check repository policy with `git status --short`. Stage each generated binary only when Git already tracks it; otherwise commit only the version/test/source changes and record generated hashes in the verification document.

```bash
git add macos-native/HelperResources/helper-version \
  macos-native/Tests/VEXNativeMacTests/NativeParityModelTests.swift
for resource in macos-native/HelperResources/awg macos-native/HelperResources/amneziawg-go; do
  git ls-files --error-unmatch "$resource" >/dev/null 2>&1 && git add "$resource"
done
git commit -m "build(macos): bundle AWG 3.1 helper generation"
```

---

### Task 5: Run Android and macOS live compatibility gates

**Files:**
- Create: `docs/verification/2026-09-03-awg31-client-matrix.md`

**Interfaces:**
- Consumes: Android release APK, native macOS app candidate, existing VEX AWG 3.0 and AWG 3.1 feature profiles.
- Produces: sanitized acceptance record with one row per platform/profile/scenario and explicit `PASS`, `FAIL`, or `BLOCKED(reason)` status.

- [ ] **Step 1: Create the verification matrix with exact gates**

Use this schema:

```markdown
| Platform | Client build | Profile | Scenario | Parser | Handshake | RX/TX | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Android | `git rev-parse HEAD` output | AWG 3.0 | fresh connect | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) |
| Android | `git rev-parse HEAD` output | AWG 3.1 Features | reconnect/network change | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) |
| macOS | `git rev-parse HEAD` output | AWG 3.0 | fresh connect | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) |
| macOS | `git rev-parse HEAD` output | AWG 3.1 Features | reconnect/network change | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) | BLOCKED(not-run) |
```

During execution replace each command cell with the observed commit SHA and every initial `BLOCKED(not-run)` with an observed `PASS`, `FAIL`, or a more specific `BLOCKED(reason)` before committing; never paste configuration or key material.

- [ ] **Step 2: Qualify Android on a dedicated emulator/device**

Run the repository's emulator preflight, install the local candidate, and exercise AWG 3.0 then AWG 3.1 Features through the app. Capture only:

```bash
adb devices
adb shell dumpsys package com.vexguard.app | grep versionName
adb logcat -c
# Perform connect, reconnect, and network-path change in the VEX UI.
adb logcat -d | grep -E 'Go backend|handshake|Tunnel.State' | sed -E 's/(Private|Preshared|HeaderProtection)Key[^ ]*/[REDACTED]/Ig'
```

Acceptance: server shows a fresh peer handshake and increasing RX/TX for both profile generations; the client recovers after the path change; no 51820 fallback appears.

- [ ] **Step 3: Qualify macOS on a disposable or explicitly inactive host**

Before testing, record:

```bash
scutil --nc list > /tmp/vex-awg31-scutil-before.txt
```

Install the local candidate only on the fixture, exercise AWG 3.0 and AWG 3.1 Features, reconnect, and change network path. Record server-observed handshake/RX/TX counts without keys. After the test:

```bash
scutil --nc list > /tmp/vex-awg31-scutil-after.txt
diff -u /tmp/vex-awg31-scutil-before.txt /tmp/vex-awg31-scutil-after.txt
```

Acceptance: expected VEX fixture state is restored, unrelated VPN services are unchanged, and both profiles exchanged traffic.

- [ ] **Step 4: Exercise previous-build rollback on each fixture**

Install the prior signed client build over the fixture while preserving application data. Confirm the saved AWG 3.0 profile still connects. Record `PASS`; if signing or a disposable device is unavailable, record `BLOCKED(signing)` or `BLOCKED(fixture)` and leave the release gate open.

- [ ] **Step 5: Commit sanitized runtime evidence**

```bash
git add docs/verification/2026-09-03-awg31-client-matrix.md
git commit -m "test(awg31): record Android and macOS compatibility matrix"
```

---

### Task 6: Final verification, rollback evidence, and handoff

**Files:**
- Modify if results change: `docs/verification/2026-09-03-awg31-client-matrix.md`
- Create outside Git: transaction artifacts under `/Volumes/D/Projects/mobile-transactions/awg31-client-implementation-20260903/`

**Interfaces:**
- Consumes: all previous task commits and runtime evidence.
- Produces: pushed client branch, verified rollback bundle, and current IBO-119 status.

- [ ] **Step 1: Run the complete source/build verification set**

Run:

```bash
npm run test:awg-upstream
npm run test:unit
npm run typecheck
export AMNEZIAWG_TUNNEL_DIR="$PWD/.local/awg31-android/amneziawg-android/tunnel"
(cd android && ./gradlew :app:testReleaseUnitTest :app:assembleRelease)
(cd macos-native && swift test)
bash scripts/build_native_macos_app.sh
git diff --check
```

Expected: every command exits 0. Record pre-existing unrelated failures separately; do not convert them into AWG 3.1 acceptance.

- [ ] **Step 2: Create the required transaction artifacts**

Preserve original hashes and create/reopen:

```text
MODIFIED_FILE
DIFF_FILE
VERIFICATION.txt
ROLLBACK.sh
```

`VERIFICATION.txt` must include exact baseline/modified/rollback commands, inputs, literal outputs, exit statuses, branch, commit, upstream refs, packaged architectures, and runtime matrix status. Do not include secrets.

- [ ] **Step 3: Verify rollback on an independent copy**

Run `ROLLBACK.sh` against a disposable copy, rerun `npm run test:awg-upstream`, Android parser tests, and Swift profile tests, and assert the copy uses the previous 3.0 refs/helper generation while the implementation worktree remains on 3.1.

- [ ] **Step 4: Review commit boundaries and push**

```bash
git status --short --branch
git log --oneline origin/main..HEAD
git push -u origin codex/ibo-119-awg31-client-support
```

Expected: clean worktree and the planned focused commits on the remote branch.

- [ ] **Step 5: Update Linear IBO-119 truthfully**

Attach branch/commit links, exact verification results, runtime matrix, and remaining signing/physical-device gates. Mark `Done` only when both platforms have fresh handshake and RX/TX evidence plus rollback. Otherwise keep `In Progress` with the exact blocking gate.

## Plan Completion Rule

Source support is complete only after Tasks 1-4 pass. Customer-release support is complete only after Tasks 5-6 pass for both Android and macOS. A green parser/build without physical handshake and traffic is not release acceptance.

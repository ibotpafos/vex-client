# AWG 3.1 Android and macOS runtime acceptance matrix

**Recorded:** 2026-09-03
**Client source build under test:** `c968e9d994745c94fbc8bf174d0b27c2bad43107`
**Pinned inputs:** `amneziawg-go` `b5928efb6ca19f0153958460c3d141f04abc5c2e`; `amneziawg-tools` `ee0f0a9aa34ff0a0da4b3433b9512781cfe02843`; Android wrapper `5c16489e2cd9ed3a0a7a27c7445bba5238132f86`.

The `Parser` column records parser/build evidence only; it is not a physical-tunnel result. No profile, endpoint, key, credential, or raw configuration is included here.

| Platform | Client build | Profile | Scenario | Parser | Handshake | RX/TX | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | fresh connect | PASS(unit XML: legacy parser/recovery contract) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | reconnect | PASS(unit XML: legacy parser/recovery contract) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | network-path change | PASS(unit XML: recovery preserves supplied profile) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | previous-build rollback | PASS(unit XML: legacy parser/recovery contract) | BLOCKED(signing+fixture: no prior signed APK and no device) | BLOCKED(signing+fixture: no prior signed APK and no device) | BLOCKED(signing+fixture: rollback could not be installed) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | fresh connect | PASS(unit XML: complete feature parser contract) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | reconnect | PASS(unit XML: complete feature parser contract) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | network-path change | PASS(unit XML: recovery preserves supplied profile) | BLOCKED(fixture: `adb devices` has no serial) | BLOCKED(fixture: no device/server observation) | BLOCKED(fixture: no dedicated emulator/device) |
| Android | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | previous-build rollback | PASS(unit XML: complete feature parser contract) | BLOCKED(signing+fixture: no prior signed APK and no device) | BLOCKED(signing+fixture: no prior signed APK and no device) | BLOCKED(signing+fixture: rollback could not be installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | fresh connect | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | reconnect | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | network-path change | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.0 | previous-build rollback | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture+previous-signed-build: unavailable) | BLOCKED(fixture+previous-signed-build: unavailable) | BLOCKED(fixture+previous-signed-build: rollback not exercised) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | fresh connect | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | reconnect | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | network-path change | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture: no disposable/explicitly inactive VEX host) | BLOCKED(fixture: no host/server observation) | BLOCKED(fixture: candidate was not installed) |
| macOS | `c968e9d994745c94fbc8bf174d0b27c2bad43107` | AWG 3.1 Features | previous-build rollback | BLOCKED(toolchain: CLT has no XCTest) | BLOCKED(fixture+previous-signed-build: unavailable) | BLOCKED(fixture+previous-signed-build: unavailable) | BLOCKED(fixture+previous-signed-build: rollback not exercised) |

## Observed preflight

### Android

- The repository has no executable Android-emulator preflight script. The available preflight, `/Volumes/D/Projects/mobile-transactions/awg31-client-implementation-20260903/deps/android-sdk/platform-tools/adb devices`, exited `0` and printed only `List of devices attached` with no serial. The installed SDK contains no emulator package/AVD.
- Therefore no APK was installed and no `dumpsys`, `logcat`, UI connect/reconnect/path-change action, server handshake, byte counter, or listener-port observation was attempted.
- All four release-signing variables were unset by presence-only check, and no release APK or prior signed APK was available. Rollback remains blocked.
- Final fresh release-unit execution at `c968e9d` passed: five XML suites, `tests="30" failures="0" errors="0"`, including `Awg31ConfigCompatibilityTest` and `VpnNetworkRecoveryTest`. The earlier focused failure was traced to a reused Gradle daemon retaining the deleted worktree-local SDK path; stopping the daemon before the same Java 17/transaction-SDK invocation restored the correct SDK classpath. This does not change the matrix's explicit physical-fixture block.

### macOS

- Candidate: `/tmp/ibo119-awg31-task4-app-validation-4e2c1cc/macos-native/build/VEXNativeMac.app`. `codesign --verify --deep --strict` exited `0`; bundled `awg`, `amneziawg-go`, and `vex-helper` each report `x86_64 arm64` via `lipo -archs`.
- `swift build` exited `0`. Parser/model XCTest is not available: `xcode-select -p` is `/Library/Developer/CommandLineTools` and `xctest` is absent.
- `scutil --nc list` baseline recorded three unrelated VPN services, all disconnected. That baseline is not a dedicated disposable or explicitly inactive VEX fixture, so the candidate was not installed or launched and no connect, reconnect, network-path, server-handshake, or RX/TX action was taken.
- No previous signed macOS build was available for preservation-data rollback testing.

## Required release gates

Provide a dedicated Android emulator/device with a signed candidate and previous signed APK, and a disposable or explicitly inactive VEX macOS fixture with a previous signed build. On each fixture, use the existing AWG 3.0 and complete AWG 3.1 Features profiles to capture fresh handshake and increasing RX/TX after connect, reconnect, and network-path change; verify no `51820` fallback; then install the previous signed build while preserving data and verify AWG 3.0 reconnects. Restore the macOS fixture and diff `scutil --nc list` before/after. Until all rows have physical handshake/RX/TX and rollback evidence, release publication remains open.

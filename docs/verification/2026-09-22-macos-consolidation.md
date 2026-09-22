# macOS consolidation — 2026-09-22

Branch: `codex/macos-consolidation-20260922`.
Base: `origin/main` at `cb2078f34e7639e941407875daba13b2e4de37b1`.
The original checkout and its unrelated uncommitted changes were preserved.
The user explicitly prohibited connecting the VPN during verification.

## Source reconciliation

| Workstream | Decision |
| --- | --- |
| AWG 3.1 (`ibo-119-awg31-client-support`) | Already in base: updated engine, complete field preservation and pre-admission validation. |
| PSK stage (`ibo-159-psk-stage`) | No unique macOS commits beyond base. |
| Native realtime (`ibo-172-native-realtime`) | Already in base: SSE idle-frame dispatch, session refresh and periodic fallback. |
| Recovery (`ibo-87-awg3-fallback-recovery`) | Base already restricts fallback to the admitted complete profile; no synthetic legacy UDP endpoints. |
| Reliability / deep audit trees | Base includes Keychain-only session migration, IPv6 PF validation, safe delayed Sparkle startup, Google auth and country node grouping. |
| `macos-client-install-reliability` at `c6594e7` | Integrated helper path/readiness, explicit teardown confirmation, sparse no-update decoding and operator probes. Retained newer compiled-in signature pins and single delayed Sparkle startup. Legacy release-channel/certificate-generation changes were excluded. |
| Original dirty checkout at `e3d3906` | Carried device/add-on models, API/UI and window changes into isolation; completed device naming, full list, removal confirmation, busy/session guards and scoped-session web fallback. |
| `macos-photo-locations-20260909` | Initially omitted in build 119. After the user's correction, its photo/motion design and three city assets were integrated into build 120, retaining current country/node grouping and reliability fixes. See the photo-design follow-up report. |

CGRX was checked before exploration. Swift and shell coverage is excluded/partial;
source review, compiler results and executable regressions are the evidence for
these changes. Narsil was not available in this session.

Resource handling follows the package resource model documented by
[Apple](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package);
the packaged path was verified against this toolchain's generated accessor.

## Fixes

- Fix the reported `Bundle.module` startup trap in country geometry. Packaged
  resources never fall back to an old developer build directory.
- Fail the build on Swift errors even inside Bash command substitution; stale
  binaries cannot be packaged after a failed compile.
- Keep helper executable, installer readiness, rollback and verification paths
  aligned at `/Library/PrivilegedHelperTools/app.vex.vpn.helper`.
- Require explicit disconnected/route/socket state before declaring teardown
  complete; malformed, incomplete or still-armed replies are rejected.
- Preserve current signing trust anchors rather than importing older
  environment-controlled trust logic.
- Show all account devices; accept an entered name; confirm removal; protect
  the active tunnel's device and serialize mutations. Refresh limits after removal.
- Handle restricted client sessions via the existing web account page. The
  server's current source allowlist does not grant all add-on/device mutations
  to client sessions; no server permission was broadened or deployed.
- Suppress stale billing/device responses after account changes. Add HTTPS
  validation to add-on checkout links.
- Add an offline build/run entrypoint and packaged resource probe.

## Verification

Completed before artifact verification:

- Offline model/API/session/SSE regression harness passed. HTTP uses a custom
  URLProtocol; all credentials are synthetic and storage is temporary/in-memory.
- Compiler-failure regression: both app/helper builders stop on failure despite
  an executable left in the previous build output.
- Country grouping, original location IDs, Russian plurals and invalid ping
  formatting passed.
- AWG admission: 65 invalid fixtures rejected, unreadable profile rejected,
  41 valid fixtures accepted; zero filesystem/command/firewall mutations.
- Admission rejection retains the prior tunnel; mocked transport failures permit
  the expected fallback path.
- The real socket client passed against temporary fake helper sockets: waits
  through connected status, rejects malformed/incomplete replies and armed
  anti-leak state. No access to `/var/run/vex-helper.sock`.
- Installer contract assertions (27) and shell syntax checks passed.

Initial artifact: version **0.1.88 (119)**, superseded by build 120 at the same
`macos-native/build/VEXNativeMac.app` path. The following observations and hash
refer to build 119; see [the design follow-up](2026-09-22-macos-photo-design.md)
for build 120 evidence.

- Release compilation passed for both arm64 and x86_64. The app, helper, `awg`
  and `amneziawg-go` each contain both architectures.
- `codesign --verify --deep --strict` passed for the ad-hoc local bundle.
- The packaged country-resource probe passed before and after moving the app
  into a temporary directory. Removing that copy's resource bundle produced
  a clean failure, without a trap or fallback to the developer cache.
- The packaged executable accepted a sparse no-update response and rejected
  incomplete available-update metadata.
- Offline launch observation passed: the same process survived 45 seconds,
  no new crash reports appeared, and Sparkle was mapped. Runtime helper and
  updater startup were disabled. The candidate was left running offline.
- UI inspection initially reached macOS's recovery dialog from the previous
  crash. After selecting Don't Reopen, the UI tool timed out repeatedly, so
  successful main-window rendering is **not verified**. A process sample
  showed AppKit event-loop and SwiftUI layout activity. Process survival alone
  is not a complete UI smoke test.
- App executable SHA-256:
  `ecf13829e0f8010e90384b9c67056d067280083a80e4a0335b6846a001c3df3c`.

## Qualification limits

- No VPN connection/disconnection, route/DNS/PF changes, helper installation,
  production changes, payments or publication were performed.
- Full XCTest suite is blocked by the installed Command Line Tools: importing
  XCTest returns `no such module 'XCTest'`. The offline harness is not a claim
  that every XCTest passed.
- No valid signing identity is available in the current keychain. The local
  candidate is ad-hoc signed; privileged-helper/installer acceptance requires
  the existing pinned identity (or the supported Apple identity).
- Tunnel handshake, traffic, sleep/wake/network-change recovery, signed installer
  rollback and Sparkle delivery require separate authorized qualification.
- macOS release truth was checked through `vex-vpn` MCP. Its report warns that
  the local backend HEAD differs from production. Backend source compatibility
  checks here are not evidence of a deployed server change.

## Remaining acceptance

1. Verify the main window with a working UI inspection session and run the full
   XCTest suite with Xcode.
2. Build using the existing trusted signing identity and qualify helper install
   and rollback in an isolated macOS environment.
3. With explicit authorization, qualify tunnel traffic/recovery and signed
   Sparkle update delivery before publishing.

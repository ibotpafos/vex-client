# Android dynamic route recovery

The Android app now consumes the same `/v1/resilience/policy` candidate contract
as native macOS. For a single authenticated AWG3 device and exit it tries direct
and qualified relay endpoints in priority order. The existing Android native
connect path requires a handshake newer than the previous native status for
each attempt, preventing a stale timestamp from verifying a new route.
Repeated route failures enter a short quarantine; a working relay stays
preferred during the failback hold. The watchdog attributes an established
tunnel failure to its active route before reconnecting through the same selector. User-initiated
server switches and rollback use that selector too.

Only `awg3_direct` and `awg3_relay` classes appear in route diagnostics. The
policy and route state are cached in Android secure storage for the current
account; an expired or unavailable policy falls back to the authorized AWG3
profile endpoint. It does not guess alternate ports or use AWG2. API policy
lookup has one 2.5-second attempt so an older API
does not hold up connection. No new dependency or native permission is needed.

This is route failover, not a physical mesh. The current server topology has
one qualified relay ingress failure domain, so a second provider must pass
real client tests before the system has independent ingress redundancy. The
server route policy and native macOS changes are integrated with their current
main branches in local worktrees. They require review, release, and a verified
server rollout before Android can use new candidates in production.

Physical-device check (Mi A1, 2026-09-25): a separate
`com.vexguard.client.routeqa` local APK assembled, passed package/version/
ABI/bundled-JS verification, installed via USB ADB, and opened without a
startup crash. After the owner signed in, one live connection started at a
German exit, recovered to an available Netherlands exit, and reached Android's
`VPN VALIDATED` state with the QA package as VPN owner. This exercises existing
location recovery, not the new direct-to-relay route policy: the production
server has not published that policy. The QA tunnel was disconnected and the
previous Incy VPN was reconnected and `VALIDATED`. The local APK reports version
1.0.55 while the update service advertises 1.0.59, so the release integration
must update the version and recheck the update flow. This APK is a local test
artifact, not a customer release. The integrated branch targets version 1.0.59;
the earlier device test does not validate its new route selector.

Integrated build check (Mi A1, 2026-09-25): the 1.0.59 local APK for
`com.vexguard.app.debug` passed package/version/ABI/embedded-JS verification,
including all three AmneziaWG native libraries. It installed over that debug
package and opened the VEX sign-in screen without a startup crash. Its account
is not signed in, so this build has not made a live VPN connection. The older
signed-in `com.vexguard.client.routeqa` package has a different application ID;
its prior connection result cannot be attributed to this build. The Incy app
was returned to the foreground after the startup check. A first local APK had
silently omitted `libwg-go.so` because the upstream Makefile split a worktree
path containing spaces; the build now uses a canonical space-free upstream
path and APK verification rejects missing VPN libraries.

Acceptance on a physical Android device, after the server route policy is
available:

1. Connect through direct AWG3 and verify a new handshake plus DNS and HTTPS
   inside the tunnel.
2. Block only the direct endpoint on the test network; verify the same exit
   reconnects through the qualified relay, records a fallback, and preserves
   access to DNS and HTTPS.
3. Restore direct access; verify the relay remains sticky through the hold,
   then a later reconnection can fail back to direct.
4. Block the relay too; verify existing profile refresh and alternate exit
   recovery still work without changing the user's tunnel keys unexpectedly.
5. Check manual server switching, app restart with cached policy, policy
   expiry, and a server version without `/v1/resilience/policy`.

The current automatic success signal is a fresh AWG handshake. A VPN-bound
DNS/HTTPS canary is still needed to detect a tunnel that handshakes but cannot
carry user traffic. Android's normal JS fetch is insufficient proof when the
user has per-app routing enabled. Keep the deterministic route selector and
watchdog independent of Jev; Jev may only advise an operator from aggregate
diagnostics.

## Release integration (2026-09-25)

The Android/macOS route changes are integrated with current mobile `main` in
`codex/dynamic-routing-release-20260925`. The separate green dynamic-IP fix
PR #49 was merged first, removing hardcoded macOS node IP exceptions. The
integrated branch passed `npm run check`, generated API contract verification,
and a Swift debug build. Its local Android QA APK passed package/version,
arm64-v8a VPN library, embedded JS, SHA-256 and APK v2-signature checks:

- Path: `/Volumes/D/Codex Storage/worktrees/vex-client-dynamic-release-20260925/android/app/build/outputs/apk/local/app-local.apk`
- SHA-256: `51813a383b63c352bf69388655b6362076c4909ed394668f6d714e0953d04eac`
- Identity: `com.vexguard.app.dev`, version `1.0.59.dev` / code `1005967`.

This debug-signed QA APK must not be published as a customer release. The
previously installed `com.vexguard.app.debug` was not signed in, and neither
build proves direct-to-relay recovery against a deployed server policy. Release
order is: merge and stage the backward-compatible server policy; run the
authenticated physical acceptance above; then produce a separately signed
Android artifact and macOS release with matching version/update metadata.
Before publication, record the previous verified OTA/update and native package
versions and prove their rollback path. If either physical data-plane check or
release acceptance fails, do not publish; keep the previous signed artifact
and policy preference, or roll back the scoped release using the existing
release tooling rather than changing tunnel keys or route/DNS/PF state ad hoc.

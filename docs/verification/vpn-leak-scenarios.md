# Repeatable routing leak scenarios

Run `bash scripts/test_vpn_leak_scenarios.sh` from this checkout. The script
uses the Go version pinned by native-routing/go.mod, shared Go caches and
temporary build files on mounted D, then executes
`TestLeakScenario*` with the race detector. All packets and sockets are in-memory
fixtures; no running VPN, route, DNS setting or firewall is touched.

`native-routing/leak_scenarios_test.go` exercises the real gVisor frontend and
AWG NetTUN with synthetic application traffic. A permitted DIRECT echo and a
DNS reply are positive controls, preventing a dead observer from proving safety.

The state matrix covers connecting, stopped AWG, revoked/expired DIRECT policy,
changed underlay and exhausted flow budget, with IPv4/IPv6 TCP/UDP packets.
DNS covers both TCP and UDP and both address families. Foreign DNS must never
fall back to physical DNS after AWG failure; revoked DIRECT names must also
remain blocked. A local empty SERVFAIL is allowed. Existing physical flows must
close on an underlay change. Capture survives these failures and is released
only by the explicit disconnect in the scenario.

These are bounded packet-routing regressions inspired by the state/DNS testing
approach in Mullvad's current `mullvadvpn-app/test`. No Mullvad code is copied.
They complement existing signed-policy and packet tests; they cannot qualify
OS-level kill switches, raw ICMP, platform VPN bypasses, daemon death, sleep or
signed physical-device releases. Preserve those separate acceptance gates.

## Isolated Linux OS acceptance, 22 October 2026

The native executable from `0babf94c81d678e4571f45abe680fd5a04abe084` also ran in
a separate Linux AMD64 container on DE against the actual NL kernel VPN. Real
TUN, nftables, an independent dual-stack witness and packet captures covered
connecting, connected, endpoint block, uplink down/rebind, transport retirement
and engine SIGKILL with the firewall retained. All 56 protected IPv4/IPv6 TCP/UDP
and DNS probes remained blocked. Positive controls received 8/8 before protection
and after explicit disconnect. Tunnel DNS, external HTTPS egress and uplink
recovery (IRTT20/20) were verified. No active personal VPN or macOS networking
was changed.

This qualifies the tested Linux namespace/OS behavior. The container has no
DHCP manager, so its fixture restores its original uplink routes before socket
rebinding. IPv6 tests establish blocking rather than IPv6 Internet service.
Physical mobile/desktop sleep, reboot, installer trust and OS policy-expiry gates
remain separate from this evidence and from the in-memory tests above.

Private reproducible receipts, captures and raw measurements:
`/Volumes/D/Codex Storage/evidence/vpn-reliability-live-20261022/`.
The server repository records this cycle in
`docs/operations/records/2026-10-22-kernel-guard-live-vpn-acceptance.md`.

## Network transition cancellation, 23 October 2026

The router previously closed registered DIRECT sockets when the underlay
changed, but an earlier dial could return afterward and register a stale
socket. Recovery-origin connections could also finish after explicit disconnect.
DIRECT DNS could return an answer from the retired network. The new
`network_transition_test.go` first reproduced 14 failures across late dial/DNS
cases. An independent replay using the original source and Go's file overlay
also received stale TCP and UDP payloads through the in-memory packet stack.

Physical work now receives cancellation when its underlay is retired, and
admission rechecks the captured network under the connection lock. Late
connections close even when a callback ignores cancellation. Late DIRECT and
recovery DNS answers are rejected. Changing networks retains capture; only an
explicit disconnect releases it. Caller deadlines and policy checks still apply.

Policy refresh is canceled with the old network and retried on the new one
without waiting for its five-minute failure delay. The refresh loop retains its
network context while waiting, so a change between a completed request and the
next timer cannot be missed. This uses context cancellation rather than polling.

The full Go module passed 59 leaf tests, including 43 leak scenarios, with
`go test -race -count=1 -timeout 150s ./...`; `go vet ./...` also passed.
The added cases cover late IPv4/IPv6 TCP/UDP dials, domain/recovery identities,
A/AAAA DNS, cooperative cancellation, repeated network changes, post-disconnect
rejection, refresh during a pending request/backoff and packet-level stale/fresh
controls. Tests use in-memory TUN/gVisor and net.Pipe, with no physical egress.

A full run exposed an existing one-second local TCP handshake timeout while
cross-compilation was active. That setup budget is now three seconds; the
150ms blocked DNS response window and the no-physical-fallback assertions are
unchanged. The initial failed run remains in private evidence.

Common-code build checks passed for Linux/amd64, Windows/amd64, macOS/arm64
executables and the Android/arm64 Go library. These unsigned candidate builds
were not installed or published. JNI/Apple packaging, physical devices, reboot
and sleep acceptance remain separate. The active personal VPN and all server
configuration were untouched in this cycle.

Private receipts: `/Volumes/D/Codex Storage/evidence/vpn-independent-hardening-20261023/`.
The final race log is `routing-tests-final.jsonl`; the original-source packet
replay is `packet-baseline.jsonl`, with mappings in `baseline-overlay.json`.

The same 59 leaf tests (43 leak scenarios) also passed as a Linux/arm64 test
binary in the existing lab image. This second run has no race detector. The
container had network=none, no capabilities, a read-only root, UID/GID65534,
one CPU and 512MiB; its configuration was inspected before execution and it was
removed afterward. Docker storage resolves to mounted D. `linux-runtime.json`
and `linux-runtime.log` retain acceptance and cleanup. This remains in-memory
packet testing, not a native Linux TUN/OS kill-switch or physical-device result.

The Android follow-up uses the production-signed 1.0.74 APK on the explicitly
isolated Mi A1. Clean-user onboarding, upgrade, real VPN, Wi-Fi loss/rebind,
Doze/wake and reboot/app-open auto-connect have their own
[device acceptance report](android-network-transition-20261023.md). It retains
the unverified LTE/IPv6/resolver-egress and unsupported boot-lockdown gates;
these logical packet tests do not close them.


The next [Android blocker and DNS acceptance](android-blocker-idle-20261023.md)
reproduces and removes a one-core idle spin in the fallback TUN service, tests
the actual component against live underlay controls, and verifies signed1.0.75
upgrade/real VPN on the same isolated device. Connected system-DNS egress is
independently observed with the Mullvad protocol. The report separately retains
an unexplained DE→NL egress transition, full-APK protected-stop and boot/LTE/IPv6
gates; component acceptance does not close those gates.

The [Android1.0.76 node-attribution cycle](android-node-attribution-20261023.md)
verifies a preserved-data signed upgrade, ordinary-UID NL HTTPS/STUN, two6/6
Mullvad-authoritative DNS batches, Wi-Fi loss/rebind, screen-off and explicit
post-reboot connection. Native-bound selected-node attribution, boot lockdown
and continuous live-underlay failure remain separate acceptance gates.

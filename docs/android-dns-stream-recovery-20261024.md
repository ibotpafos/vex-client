# Android DNS and transport candidate, 24 October 2026

Status: private Android 1.0.82/build90/code1008290 passed bounded acceptance on
the isolated Mi A1. Android 1.0.81 was rejected after a native crash; its evidence
is retained below. No release or OTA was published. No server operator
configuration or owner iPhone was changed. Normal authorized stand login and
profile requests used the ordinary client APIs. Google sign-in used the stand's
existing account without reading passwords or codes. Updates preserved UID,
first-install time and authenticated session; the reboot cold start preserved it.

Three defects have deterministic regressions:

- Unanswered TCP DNS immediately failed on EOF/UnexpectedEOF. One reconnect now
  uses the same encrypted dialler and DNS server, within the original context and
  one five-second total deadline. Cancellation closes blocked reads. Complete
  responses still undergo the existing ID/question validation. No physical DNS
  fallback was added. This follows
  [RFC 7766 section 6.2.4](https://www.rfc-editor.org/rfc/rfc7766#section-6.2.4).
- Completed UDP DNS sockets held the shared application flow budget for 30
  seconds because UDP has no close notification. A packet-level regression with
  a two-flow budget demonstrated starvation after both application sockets were
  closed. DNS mappings now expire after one idle second, using the actual I/O
  clock. The regression verifies recovered capacity and a later successful query
  through the same application UDP socket. The flow limit remains unchanged.
- The pinned upstream network adapter could close its packet channel while
  `WriteNotify` was sending, producing a race and `send on closed channel`.
  The small adapter is preserved locally with its MIT license and upstream file
  SHA in `native-routing/internal/awgnetstack/UPSTREAM.md`. Callback admission is
  retired under a mutex, shutdown cancels blocked sends, and admitted callbacks
  finish before channels close. Close is idempotent. The AWG cryptographic core,
  module versions, wire format and profile parameters are unchanged.

The original adapter failed the blocked-notification test with the channel panic;
concurrent packet/shutdown regressions now pass. The full pinned Go1.26.9 race
suite passes with all three changes. Focused DNS tests also passed on Go1.27.3.
`npm run check` passes after the Android version sync; iOS metadata bytes are
unchanged. The first full runs retained their failures: an existing one-second
refresh-test deadline, and then the upstream shutdown race reproduced with the
original `dns.go` and new DNS tests excluded. These were not hidden by skipping
failed acceptance checks.

The final DNS stream/datagram and adapter shutdown ARM64 regressions passed
on Mi A1 with Go1.26.9. They exercise memory-only packet fixtures; signed-APK
traffic acceptance was subsequently completed separately below. Standalone run-as
OS socket experiments failed to establish a qualified VPN path and remain
rejected: the Go dialler run hit its 120-second test deadline, and the bounded
Android libc smoke test returned EINPROGRESS. They are neither a production
dialler failure diagnosis nor APK acceptance.

The field measurements also identify limits of server attribution. On FI, selected
DNS replies left the server promptly despite phone UDP timeouts; the exact loss
component remains unresolved. INCY's one-shot UDP and simple TCP trials did not
provide a complete fix. Similar failures also appeared on the installed VEX1.0.80.
A common Mi A1 Wi-Fi scan produced synchronous DNS/TCP/HTTPS stalls without VPN
and was reproduced while connected to DE. Those particular spikes cannot be
attributed solely to DE CPU steal. This does not assign every DNS loss or DE
latency spike to scanning, resource pressure, or the shutdown defect.

Switching receipts are retained even when they still show the previous egress or
a mix of nodes. Steady-state measurements require a fresh matching-node traffic
confirmation; a selected label or unchanged Android VPN Network is insufficient.
The INCY client itself was not patched, and no iPhone acceptance is claimed.

Private measurements, source overlays, failed attempts, screenshots and cleanup
receipts reside under `/Volumes/D/Codex Storage/evidence/incy-dns-latency-20261024/`.
No authenticated screenshots, raw profiles, customer identities or keys belong in
this commit. Final private candidate evidence and device cleanup are below.

## Rejected 1.0.81 and fourth regression

Private run40116784871 successfully signed sourcecc63b55/tree628c7b63. Local ZIP
and APK digests, signer, both ABIs, JNI export, boot service, runtime and upgrade
compatibility passed. Installed bytes matched the verified APK. FI repeated
workload improved from96/108 DNS and22/24 STUN to108/108 and24/24; all36 HTTPS
passed. DNS successful tails around1s remain. DE gave105/108 DNS,24/24 STUN and
all36 HTTPS, with isolated successful delays up to2.4s and cold transition failures.
These samples do not establish zero loss or a fleet latency SLO.

After DE the app exited with native SIGSEGV. The crash PC dereferences the null
receiver at+0x30; its LR identifies the canceled happy-eyeballs cleanup call in
`dialQualifiedAddresses`. A failed gVisor dial can carry a typed nil through
`net.Conn`; its interface is non-nil, so the old cleanup called Close on it.
The regression reproduces the forbidden method call after the winning dial
cancels a losing failed dial. Cleanup now owns only successful connections
(`err == nil`), and a second regression retains successful-loser close behavior.
This is a previously unchecked cancellation path, not proof that every DNS or
latency failure caused the crash, or that 1.0.81 introduced the defect.

The first Wi-Fi-return controller aborted before changing Wi-Fi because the VPN
was already gone. Its following probes were rejected as direct/non-inventory;
no network-return acceptance is claimed from them. A delayed picker render also
caused a temporary RU selection; it was excluded and DE was selected using the
fully rendered UI. No owner device or production configuration was changed.
Full Go1.26.9 race/vet and npm checks pass after the fourth fix. Final ARM64
DNS and cancellation regressions pass on Mi A1; the temporary binary was removed.
The corrected signed 1.0.82 subsequently passed the bounded acceptance below.

## Private 1.0.82 acceptance and cleanup

[Run 40120283209](https://github.com/ibotpafos/vex-client/actions/runs/40120283209)
built source `683186a3f8e2bb0a433fba7892fa4ff9db6a1cd9`, tree
`673e040b1905901c9b9fc8adddd469ade4eef170`, with orchestration
`a8197eb700d6db455d0984f937d53c6a56b8471f`. ZIP digests, receipt/source binding,
expected signer, both ABIs, JNI export, runtime, boot service and upgrade checks
passed locally. Both Go native libraries differ from rejected 1.0.81. Installed
APK bytes matched SHA256
`8991c01643bb684b83a73897a226019852d348e7749ecd9100845b1650f00eb3`.
Signing-material cleanup completed in CI. No publication occurred.

Each initial workload comprised three consecutive batches. Ordinary UID traffic
confirmed all three successful egress echoes matched the selected node before
acceptance; every successful workload echo was also checked afterward.

| Server | Application UDP DNS | DNS p95 / max, ms | STUN | Numeric + named HTTPS |
| --- | --- | --- | --- | --- |
| FI Sisu | 108/108 | 74.6 / 79.3 | 24/24 | 36/36 |
| DE Kern | 108/108 | 198.6 / 210.2 | 24/24 | 36/36 |
| NL Noord | 108/108 | 193.2 / 248.9 | 24/24 | 36/36 |

Application UDP DNS is intercepted and carried over encrypted TCP in VEX. These
are not different upstream UDP resolver benchmarks. Numeric TCP connect only
confirms a virtual ACK; HTTPS and STUN verify external traffic. Short sequential
measurements, potentially concurrent infrastructure work and cached example.com
answers do not isolate all causes or establish a fleet latency SLO.

A deliberate DE Wi-Fi-settings scan retained the process and VPN: DNS36/36 and
HTTPS12/12, with DNS/HTTPS stalls up to1.71/1.61s; STUN7/8, one timeout. Actual
Wi-Fi disable/enable interval8.702s produced all four offline negative probes,
then automatic DE return without app reconnect and another108/108 DNS,24/24 STUN,
36/36 HTTPS. DNS tails after recovery reached1.29s. Offline failure does not
certify a live-underlay kill switch. Across these five workloads: DNS468/468,
HTTPS156/156, STUN103/104; the scan failure is retained.

Screen sleep/wake lasted21.192s with observed Dozing; process and VPN survived
and FI4/4 followed. Deep Doze was not forced. Twelve workload snapshots retained
one process for602.83s before the deliberate reboot, with no new app crash entry.
Reboot tested VPNoff cold launch after user0 unlock, preserved login/Noord and
manual NL4/4 reconnect; Always-on/lockdown boot certification was not repeated.
No new app crash was observed after reboot. Early-EOF fault injection remains
unit/ARM64 fixture evidence; no live-server early-close injection was performed.

Final native state isNoord/off, INCY3.8.1 FI Sisu/off. Original Wi-Fi/data/airplane,
timeout, Always-on/lockdown and Private DNS settings match baseline. Owned QA
fixture v5 was UID/digest-verified before uninstall; its test key was removed,
temporary unit binaries and Wi-Fi trial service are absent. Google/Instagram
sessions were not cleared. Read-only Mac DNS and VPN-service digests match the
initial values. Scope isCLOSED; do not replay its controllers.

These four owned-client fixes passed this acceptance. INCY and actual iOS remain
separate: the exact loss component after selected FI DNS replies and every DE
latency spike were not resolved by this record. The scan UDP loss demonstrates
that the stand's radio can still affect traffic.

# Android DNS and transport candidate, 24 October 2026

Status: Android1.0.81/build89/code1008189 was built privately, installed and
rejected during physical acceptance after a native crash. Android1.0.82/build90/
code1008290 adds the typed-nil cancellation fix below. Production publication,
OTA, server configuration and the owner's iPhone are outside this change. The
owner authorized autonomous login on the stand, and normal Google sign-in using
its existing account succeeded without reading codes or credentials. Update-r
preserved the application UID, first-install time and authenticated session.

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
traffic acceptance remains a separate check. Standalone run-as
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
this commit. Release and final device evidence must be added after actual
candidate installation and traffic acceptance.

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
Signed1.0.82 and its physical acceptance remain required.

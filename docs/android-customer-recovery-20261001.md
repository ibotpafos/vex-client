# Android customer failure audit and recovery cleanup — 2026-10-01

## Read-only operator evidence

Primary `vpn_client_telemetry_audit` and three protected customer contexts were
read without exposing customer identities or changing devices/access. The
already-implemented `failure_codes` section was read through the current server
worktree's stdio MCP because the installed primary MCP still has the older schema.
No new dependency, query implementation, credential or external configuration was added.
All aggregate pages were followed using `next_offset` (six pages total).

- Seven days: 1867/1867 consented diagnostic reports processed. Customer failure
  diagnostics: 123/1213 (10.14%); connected HTTPS failures: 36/799 (4.51%).
  These are diagnostic sample rates, **not connection-attempt availability**.
- Recent 24 hours: 305/305 overall reports, 113 customer reports; 9 failed,
  69 connected, no connected DNS/HTTPS failures. The newer operator Dev cohort
  is not a customer rollout and must not be used to claim customer recovery.
- Recent customer 1.0.59: three `hot_profile_connect_failed`, one
  `profile_query_failed`. Customer 1.0.57: two unclassified plus one each
  entitlement fetch, profile query and active refresh failure.
- Two protected recent cases have expired trials. The third has active paid
  access, latest diagnostic `ok`, and no recent traffic; node NL infrastructure
  metrics look healthy, but authenticated tunnel acceptance is missing.
  A retained node-command mismatch signal is not proof of a current node outage.
  No subscription extension, profile regeneration, node restart or customer email occurred.

## Confirmed source defect, not inferred customer resolution

`useVpnConnectionFlow.connectCurrentVpn` previously bypassed failed-tunnel
cleanup when resolving the fresh/alternate profile raised a non-404 API error
**after** a transport failure. The actual callback reproduces this using the
existing TypeScript/Node VM test pattern, with only API/native boundaries mocked.
The fix reuses `cleanupFailedVpnConnection`; no new recovery abstraction or library.
It retains the original error, anti-leak release policy and admission-error guard.
Successful connections and errors persisting a selection after connection do not
stop a verified tunnel. An actual native disconnect rejection still cannot be
claimed to have cleaned the tunnel; the original recovery error is retained.

Baseline/modified/rollback use the same eleven fixture inputs:
- 403/503 after handshake failure: no cleanup / one cleanup / no cleanup;
  successful cleanup changes mocked native state connecting → disconnected.
- Success, admission rejection and post-connect storage error preserve the tunnel.
- Probe exits 0/0/0; regression exits 1/0/1. Restored hash equals the baseline;
  native patch reconstruction is byte-exact. Full `npm run check` exits 0.
  Node experimental/module warnings remain recorded rather than suppressed.

Transaction roles and literal commands/stdout/stderr are outside Git:
`/Volumes/D/Projects/mobile-transactions/android-release-20260930/customer-audit-20261001/recovery-cleanup/`.
CGRX reports partial dynamic coverage and excluded test/config paths; source and
actual checks were inspected instead of treating missing edges as proof.

## Release continuity

The two approved previews remain terminal rolled_back. Their signed APKs/updates
still belong to source `2ce0a26075ceed1b95cdc8dcfab9024f0673c20e`; do not relabel
those retained artifacts as containing this new fix. No third preview or production
OTA/APK publication, DNS or VPN infrastructure mutation was performed in this audit.
This change needs a fresh candidate and device acceptance before release.
Remaining gates: modern Android/Doze/process/network, real tunneled egress/leak/speed,
brief downloading notice capture, backend release-truth reconciliation and review.

# macOS C40 — post-promotion private retirement (offline)

## Scope and authority

Extend existing bounded descriptor-owned stores/WAL and exact nonce CAS; no new
library or privileged root protocol. `PromotionRetirement` is canonical schema1,
0600, max16KiB metadata: original and terminal tuples, material/nonce/capability/
purpose/staged-byte digests, exact commit receipt OR source replay-fence digest.
No raw capability, config, PSK, token, account, installation, TTL or admission.

After actual fresh root evidence, signed/current candidate validation and cache /
exact event completion, persist/read back terminal WAL BEFORE nonce or private
file removal. Initial opt-in, receipt recovery, candidate continuation and source
restoration use the same finisher. Source restoration retains inactive candidate
stage/events and the replay fence; source metadata never becomes admission.

Every explicit Settings cleanup retry obtains TWO exact fresh authenticated
read-only root receipts/snapshots, including when nonce/material are absent.
Only private deletion/index/memory completion follows: no authorize/adopt/
replace/commit/recover/config/DNS/cache/admission/normal-connect ports. Exact
remaining nonce, secrets, WAL and source fence are checked; changed custody is
preserved. Missing files are accepted only under matching terminal WAL, never as
root proof. Active owner/account/install/helper withdrawal vetoes after await.

Staged raw bytes and owned index are validated before any private deletion; exact
stage CAS and index write/readback support file-gone/index-present retry, preserve
unrelated tuples, and reject unsafe/corrupt/unknown index metadata. The terminal
phase is written/read back only after all required files/index/nonce are absent.
Cancellation retirement, immutable consent purpose, consumed/rebound nonce,
root journal/receipt/cancel WAL and source replay fence are unchanged/preserved.

A NEW explicit signed normal root admission can change only the source-retirement
cleanup-proof basis, then clear its replay fence LAST. A private-only retry of
that basis leaves the fence in place. No metadata/purge/status/expiry clears it.
A pre-WAL legacy orphan with missing nonce remains fail-closed at the local
`TODO(post-promotion-legacy-orphan)`; no invented nonce or absence authority.

## Executed evidence

Permanent transaction roles remain under
`/Volumes/D/Projects/mobile/macos-release-transaction-20261001`.
Current cycle evidence is in `cycle-40-post-promotion-retirement` and the retained
cycle27 command ledger, with literal stdout/stderr/status and hashes.

The new compiled evaluator has131 actual cases:104 receipt/journal/source cases,
26 opt-in/private stage/index cases and1 explicit-UI/unfinished-legacy wiring
check. Deterministic IO exceptions are injected at real owned-file boundaries;
fresh store instances are NOT an OS process crash/power-loss/fsync test.

Frozen65-Python evaluators run identically on BASELINE/MODIFIED/ROLLBACK copies:
new contract is honestly ABSENT on BASELINE/ROLLBACK (one diagnostic exit1;
missing runtime branches NOT executed), actual131 cases on MODIFIED exit0.
Previous cancellation81/root58/client23/pre-stage86/client44/owner70/client68/
material27/App39/journal115/cutover53 and ordinary-push/active-pending stay exit0
in all states. Literal baseline and rollback stdout AND stderr must match.
All15 main/cycle27–40 portable rollback variants execute on separate disposable
copies; bytes/modes/new-file absence/scoped diff reapplication must be verified.

Universal offline0.1.114(153) reuses successful152 command array, changing only
build identity. Both architectures, strict ad-hoc signatures/resources/updates
-disabled and ZIP roundtrip bytes/modes/symlinks are checked. Public preflight
must remain exit1 (Developer ID required), NOT public-release acceptance.
Earlier151/152 packages and pre-final aggregates are retained, not final acceptance.
No install/normal app/helper launch/service restart/private signing-key access/
publish/active VPN/routes/DNS/PF operation. Read-only VPN observation is separate.

## Limits / next

131 cases and offline package do not establish full Android parity or a public
release. Next: exact fresh-root reconciliation of pre-WAL legacy orphan custody;
then isolated actual Mac/current-console UID/crash/power-loss/install/connect/
update/leak acceptance, Developer ID/notarization/APNs provisioning and complete
Android parity/release acceptance. Persistent full goal remains ACTIVE.

# Cycle 34 — explicitly authorized client receipt recovery

## Scope

The same macOS release-readiness candidate now has explicit Settings actions for
authorize, recover and cancel. This is unfinished OWN PSK transaction recovery,
not ordinary connect, arbitrary live-owner attachment, installation or a release.
No installed app/helper, VPN routes/DNS/PF or production state was changed.

## Observed source behavior

- Exact source/candidate canonical bytes are retained before candidate staging in
  a separate bounded private material record. Stored source metadata is not admission.
- Capability custody is separate, owned/private/no-follow and written before
  authorize RPC. Lost ACK retries the identical capability; local TTL is never extended.
- Only the original current process can authorize/cancel. A different process
  requires existing consent; root separately authenticates UID/PID/start identity.
- Recovery independently checks current authenticated session/account/install,
  managed device from accountDevices, client key, selected/target location, routing,
  paid access and current signed staged envelope before and after RPC boundaries.
- Candidate fields are rebuilt using the existing key and verified policy; all
  canonical bytes must match retained material. Only the retained endpoint
  resolution is reused (same signed port), with no fresh DNS/API/key creation.
- Ownership ACK is not commit proof. An ephemeral new-owner tuple obtains a root
  receipt, a separate narrow canonical rebind preserves nonce/material/generation/
  prior handshake, and a second independent receipt precedes cache promotion.
  Ordinary cross-process load/save remains rejected. Transaction + random new-owner
  digest binds this adoption; no fabricated root adoption identifier is introduced.
- A proven physical candidate remains visible on cache failure. Strict current-process
  cache-only retry obtains two fresh root proofs without re-adoption or a live capability;
  an expired signature or failed proof still denies cache work. No reconnect is performed.
- Only matching current-owner/device/rotation/version queued triggers are drained after
  successful proof and cache promotion. Queue failure retains proof-only retry; unrelated
  events/owners survive. Exact capability/material and staged-envelope cleanup follows.
- Original-owner cancellation remains available after local consent expiry or changed
  paid/push/selection scope: it admits no profile and still requires root exact capability
  and original kernel peer/start identity. A different process cannot cancel.
- New client RPC errors are constant/redacted. No raw capability/config/keys enter
  UI, metadata intents, diagnostics or evaluation stdout.
- Confirmed explicit consent skips generic app-quit teardown. The independent
  root pending-transfer fence covers lost ACK/expiry/crash/helper recreation.

## Evidence

Frozen evaluators are retained outside the candidate in
`/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-34-client-restart-material/frozen-evaluator-v9/`.
Actual compiled source gates: 68 custody/RPC/rebind checks, 27 signed/material
checks and 39 explicit app-body checks; all 134 passed in offline inert fixtures.
The 53-case existing PSK cutover matrix also passed. The full aggregate, final
universal package and disposable rollback outputs are recorded in the permanent
`VERIFICATION.txt` and cycle-34 closure records, not fabricated here.

Baseline/rollback lack these APIs and both identically report 134 missing
client-restart requirements. That is capability absence, not a claim that all
134 runtime branches executed against an implementation absent at baseline.
Previous compiled cross-process rejection/root tests remain separately retained.

## Deliberately unfinished

- Journal ACK never promotes. Explicit protected source restore/candidate resume
  after consent needs its own runtime/intent/proof gate. This code retains evidence
  and fails closed; it does not infer recovery from dead PID/status/private metadata.
- Consent before the first physical mutation and the crash window before root
  journal persistence remain unfinished; original live-owner consent must be
  bound before staging without weakening old helper compatibility.
- Exact private cleanup retry after completed promotion needs a separate explicit
  no-adoption action if disk deletion fails. Adjacent TODO marks that path.
- Actual OS-process death/restart, current-console UID/signing, installer/update/
  leak/power-loss behavior require a separate test Mac/VM. Unit ports do not prove it.
- Developer ID/notarization/APNs provisioning and Android per-app parity remain
  release gates. Existing destination-route helper cannot enforce an app picker.

Goal remains active. No production release, publication or full crash recovery claim.

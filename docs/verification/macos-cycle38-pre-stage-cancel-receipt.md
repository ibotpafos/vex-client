# macOS cycle38: durable pre-stage cancellation proof

## Bound operation and safety

Candidate: `/Volumes/D/Projects/mobile/vex-client-release-readiness-20261001`,
branch `codex/macos-release-readiness-20261001`.
Parent: `9d1a9132ed59c53e4a6f5c14051b736ff279629b` (completed C37).
Continue the recorded lost-cancel-ACK boundary. The original live checkout,
installed app/helper, active VPN, routes, DNS, PF and production are not written.
No normal app/helper launch, installation, release or private signing-key access.

## Changed contract

`ProtectedPreStageConsentStore.cancel` writes a bounded canonical root-private
`ProtectedPreStageCancellationReceipt` (0600) and strictly reads it back BEFORE
deleting consent. It contains the original immutable consent, its digest,
original kernel UID/process-start/token binding, cancellation time and a source
or completed-root-receipt evidence digest. No raw capability/config/key is copied.

The wire ACK remains exactly `stage-cancelled transaction_id=UUID\n`: C36/C37
clients remain compatible. Missing consent alone is never proof. An exact
original live authenticated owner can replay that ACK after remove/response or
client ACK-marker-write loss, including after expiry/helper restart. The retry
does not rewrite the proof, renew TTL, grant replacement, transfer ownership,
admit a profile or change any physical network port. Runtime still clears its
one-use grant before cancellation. Root journal and commit receipt stay intact.

A pending journal/transfer denies cancellation. Compatibility is retained for
metadata-only cancellation after exact source recovery or a completed root
receipt; neither is evidence that the client send-intent was unconsumed.
`requireUnconsumedStageIntent` remains conservative: false send-intent cannot be
deleted/promoted using an ACK, even if a crash could have preceded the RPC.

`authorize`, `attach`, `verifyPreparedAttachment`, restart authorization and
owner-transfer admission reject the cancelled nonce/capability. A malformed,
unsafe or unknown cancellation file fences ordinary/watchdog cleanup even when
consent is absent. A WAL-only partial delete remains fenced. A completed proof
alone is inert. One latest receipt is retained; snapshot/expiry/retry never
erase it. Only a different explicitly authorized, exactly proved cancellation
can supersede it. A fresh runtime nonce and fresh capability are mandatory;
superseding private metadata cannot resurrect an earlier one-use runtime grant.

Client `cancel` retains the existing strict ACK parser, capability and nonce
until its exact owned-purpose marker write/readback succeeds. It rechecks
current material after that write before deleting capability. A marked private
cleanup retry needs no second root RPC and cannot become adoption/admission.

## Executed focused checks

Commands (all via `rtk proxy` and retained `run_check.py` literal ledgers):

- `python3 scripts/tests/test_macos_pre_stage_cancel_receipt.py`: 58 compiled
  root Runtime/store/canonical file/UID/start identity/IO-boundary cases, exit0.
- `python3 scripts/tests/test_macos_pre_stage_cancel_client.py`: 23 compiled
  AppState/helper/coordinator/nonce-CAS/actual private-file cases, exit0.
- Existing `test_macos_protected_pre_stage_consent.py`: 86/86, exit0, including
  old exact cancellation ACK and legacy journal/receipt behavior.
- Immutable baseline copy: original 44 client and 86 root checks pass, exit0.

Root physical ports are inert. Client authenticated RPC is an inert idempotent
root-cancellation model; root WAL behavior is independently compiled above.
This is not a live app-to-installed-helper integration claim. IO callbacks
model failures before/after atomic writes/removal; real OS crash/fsync durability
and current-console UID/code-signing acceptance are not claimed.

Intermediate compiler/test failures remain literal: a compiler rejected source
modified concurrently during the first baseline attempt (repeated against the
immutable archive); new fixture throwing expressions were corrected; the retry
write fence was narrowed to authority files, allowing the existing operation
lease marker; foreign-process setup now removes its old post-journal fixture
capability before creating distinct stage-purpose custody. Production guards
and old assertions were not relaxed.

## Transaction and remaining release work

The final frozen evaluators run against identical BASELINE/MODIFIED/ROLLBACK
inputs. The new cancellation-WAL contract is absent in baseline/rollback:
one diagnostic, exit1, absent runtime branches NOT executed. The modified
contract runs the actual 58+23 cases, exit0. Older nine-kind regressions are
required to pass all three states, with byte-identical baseline/rollback stdout
and stderr. Main and cycle27–38 rollback variants run only on disposable copies,
then the scoped patch is reapplied. Existing four permanent roles are extended,
not replaced. Universal offline0.1.114(149) uses the newest successful148 command
array, changing only build identity. Public release still needs Developer ID.

Next exact code boundary: `TODO(stage-cancel-retirement)` in
`NativeProtectedRestartStore.removeMaterial`. Purpose/material deletion is not
one filesystem transaction; a failure after deleting purpose must retain
provable exact cleanup custody rather than infer a missing marker or renew
restart authority. This is a distinct remaining scoped operation, not hidden by
the new root cancellation proof. Real isolated Mac crash/install/connect/update/
leak testing, Developer ID/notarization/APNs provisioning and remaining Android
parity/release acceptance remain unfinished. Persistent release goal is ACTIVE.

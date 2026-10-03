# C39 — durable private stage-cancellation retirement

## Scoped change

`NativeProtectedRestartStore.StageCancellationRetirement` is a bounded canonical
metadata-only private WAL. Exact cancelled `StageConsent`, material digest,
unchanged ACK digest and optional capability-record digest precede all deletes.
The ACK digest is **local custody, not root authority**. It stores no raw
capability, config, key, account identifier, expiry or new admission permission.

`NativeProtectedRestartCoordinator.cancel` preserves the existing authenticated
root ACK and root cancellation WAL protocol. The client writes and reads back its
retirement WAL before removing the raw capability. `VEXAppState` then removes
only the exact unconsumed original-process nonce, validates pinned custody and
finishes purpose/material retirement. A consumed or rebound nonce vetoes cleanup;
the store finisher independently requires the nonce file to be absent.

`phase=retired` is persisted only after capability, purpose and material are
observed absent. Every terminal write/readback rechecks absence. A fresh store
can retry with either or both secret files absent, but only under exact durable
WAL, authenticated current account/install, original process and nonce CAS.
The latest record survives secret purge and repeated cleanup. Neither a timer,
missing file, metadata, root snapshot nor cancellation ACK grants admission.
Root cancellation/journal/receipt and source restoration fence are untouched.

Immutable `Material.stagePurposeRequired=true` is written with opt-in material
before purpose/capability. Legacy nil encoding remains byte-compatible. Both
pre-send `stageConsentPending=true` and conservatively consumed `false` retain
their protocol; the actual saved nonce additionally fences legacy material.
Missing purpose cannot turn either into post-journal authorization or a new TTL.
An old completed retirement remains inert when a genuinely different explicit
nonce is retained by the existing signed/current root-bound stage callback.

## Observed focused check

`rtk proxy python3 scripts/tests/test_macos_stage_cancel_retirement.py TARGET`
compiled actual App methods, helper wrapper, coordinators and descriptor-owned
private stores: **81 cases, 0 failures, exit 0**. It checks twelve deletion/write/
readback boundaries, pinned secret reappearance, exact fresh-store retry, strict
canonical bounded metadata, modes/symlinks/hardlinks/directories, directory swap,
material/capability/purpose drift, current-owner withdrawal, foreign scope,
legacy migration, missing-purpose provenance, consumed-intent veto and retained
source replay fence. RPC is inert; root authority is tested separately by the
existing cancellation matrix. No OS crash, power-loss or installed integration
acceptance is implied by deterministic owned-file failure injection.

## Transaction evidence and remaining work

The resumable transaction and literal command records are under
`/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-39-stage-cancel-retirement`.
The existing four permanent artifact roles are extended, not replaced. Final
aggregate, frozen baseline/modified/rollback, disposable rollback and package
results are recorded there by the closure runner, not inferred from this note.

`TODO(post-promotion-retirement)` remains beside `removeMaterial`: non-cancellation
commit-receipt/source-restoration cleanup needs its own exact durable terminal
evidence across private deletion and nonce completion. Required missing purpose
is already fenced; this cycle does not claim that separate cleanup is complete.

An isolated Mac/VM is still unavailable. Developer ID/notarization/APNs
provisioning, deployed signer attestation, actual AF_UNIX/current-console UID/
signing/crash/install/connect/update/leak acceptance and remaining Android parity
are unfinished. No installed app/helper launch/install, private signing-key
access, publication or active VPN/routes/DNS/PF mutation is part of this cycle.

# Cycle 33: explicitly authorized helper ownership transfer (offline)

Candidate: `/Volumes/D/Projects/mobile/vex-client-release-readiness-20261001`.
Baseline: `529f733465d079641df64a688acf5fa8d9a7077c`.
The original `/Volumes/D/Projects/mobile/vex-client` checkout is not modified.

## Implemented boundary

`HelperCommand`/`HelperRuntime` add `protected-authorize-restart`,
`protected-adopt-restart`, and `protected-cancel-restart`. This is an explicit
ownership transfer, NOT tunnel activation, recovery, reconnect or commit proof.
The old live authenticated owner must consent against an exact existing journal
or committed receipt, transaction/source/candidate/token hashes and same UID.
The new socket peer is checked by the existing audit-token, console-user,
live-code signing and process-start-identity gates, repeatedly at write boundaries.
A dead PID, ordinary helper status, cached profile or root receipt alone is not
permission. Unknown/legacy controllers fail closed; ordinary commands retain
their prior behavior when no pending transfer exists.

The caller supplies a 256-bit capability. Only its SHA256 is persisted; requests
and raw capabilities are never logged/echoed, including misrouted legacy-parser
errors. A root-private canonical bounded record holds exact ownership/session and
evidence hashes, a 120-second authorization window, and a write-ahead phase.
New owner tokens use `SecRandomCopyBytes`. No raw config/private key/customer
identity is duplicated into the transfer record.

`authorized` and `adopting` fence ordinary operations, both watchdogs, startup,
stranded-state cleanup and protected replacement commands. Corrupt, unreadable,
unsafe or expired authority remains fenced; expiry is not permission to disable
protection. The original live owner can explicitly cancel an unused authorization,
including an expired one, but cannot abandon a prepared adoption.

Under the existing kernel operation lease, `adopting` is written/read back BEFORE
owner, session and journal/receipt ownership fields. Each dependent private write
is read back and all non-ownership material, phase, handshake floor and DNS bytes
are revalidated. Several atomic writes are not claimed to be one filesystem
transaction. Partial writes retain the fence and can be completed only by the
same new PID/start identity and capability. A different subsequent process cannot
inherit that transaction merely because the previous process died.

A bounded `transferred` completion receipt enables lost-ACK retry by that exact
new process, not another transfer. Fresh consent by the current proved owner is
required for a later restart. Existing root commit receipt verification remains
separate and still rejects changed DNS/routes/socket/handshake/material.

Ownership transfer depends on files only: no command runner, tunnel/PF/DNS/route
method, API, key generation, profile promotion or queue ACK is invoked.

## Frozen evidence

`/Volumes/D/Projects/mobile/macos-release-transaction-20261001/cycle-33-authorized-app-restart/frozen-evaluator-v5/test_macos_protected_owner_transfer.py`
is identical for BASELINE/MODIFIED/ROLLBACK. It executes actual production
parser/runtime/store/controller code with inert ports and owned disposable files.

- BASELINE: 70 cases, 61 failures, exit 1 (new protocol absent).
- MODIFIED: 70 cases, 0 failures, exit 0.
- ROLLBACK: requires the identical baseline stdout/exit and pristine byte/mode
  manifest, followed by scoped patch reapplication.

Cases include journal/receipt/prepared-source transfer, helper recreation,
lost-ACK retry, replay denial, wrong UID/peer/signature/PID start/tuple/capability,
expiry/backward time, ordinary/watchdog/startup fences, every ownership-write and
rename-sync fault, partial-transfer retry, current-proof separation and actual
private-file permission/symlink/hardlink/canonical/size checks. Temporary parents
are created and resolved by Python before Swift binds any new child. Earlier
compile/fixture alias failures and corrected evaluator versions remain in the
external evidence ledger; production no-follow checks were not weakened.

The existing offline aggregate includes the new evaluator. The universal package,
all eight rollback variants (original and cycles 27–33), matching commands/inputs,
literal stdout/stderr/statuses/hashes, reapplication, and final role reopen are
recorded in `/Volumes/D/Projects/mobile/macos-release-transaction-20261001/VERIFICATION.txt`.
No historical completed evaluator is replayed as a new result.

## Not proven / next implementation

This is NOT full app-process restart support or release readiness. The app still
needs explicit recovery UI, private capability custody, fresh account/install/key/
signed-stage/user-intent validation, exact retained canonical material recovery
and authoritative post-transfer proof before cache promotion or ACK. Consent
currently requires an existing journal/receipt; a crash before that authorization
is not covered. The adjacent runtime TODO marks this unfinished integration.

Actual installed signing/console-user provenance, OS-process/power-loss recovery,
installation/connect/update need an isolated Mac/VM. Developer ID/notarization,
deployed signer attestation and remaining Android parity/release acceptance remain
open. No installed app/helper normal launch, installation, service restart, live
VPN/routes/DNS/PF mutation, private signing-key access, release or publication is
performed. The full goal stays active.

# macOS cycle 30: durable helper commit proof and lost-ACK reconciliation

This is a source-only/offline candidate, not public release acceptance.

## Actual production path

The helper records a bounded root-private commit receipt, atomically writes and
fsyncs it through the existing LocalFileSystem writer, and verifies readback before
removing the protected recovery journal or acknowledging commit. It contains only
transaction/config hashes, owner-token hash, process identity and handshake facts,
not profile bytes, raw owner token, private keys or customer identity.

Authenticated `protected-receipt` accepts the existing strict four-field tuple.
It requires the SAME live PID/start identity/token, no pending recovery journal,
exact durable transaction/source/candidate/owner identity and a currently healthy
uncached candidate/handshake. Missing, malformed, mismatched, stale, future,
unreadable or unsafe evidence is rejected. Lookup does not attach an owner, modify
session/config/network, invoke quick/PF/DNS mutations, or recover a source.

The actual disk reader anchors every ancestor with O_NOFOLLOW and checks a bounded
regular owner-only file with one link, owned by the executing helper UID. It rejects
symlinks, traversal/NUL, wrong modes, hard links, oversized and invalid UTF-8 data.
The memory-port protocol default is backward compatible; production LocalFileSystem
always overrides it with the real descriptor checks.

A `commit_receipt_protocol=1` capability is explicitly advertised. The app coordinator
queries the EXACT original durable receipt after a lost/malformed commit ACK, and
on a bounded retry of the original uncertain commit. Verified proof promotes the
physical candidate without repeating stage/replace/recover/reconnect. Receipt lookup
rechecks current account/session/intent via caller guards; changes preserve pending
state and never trigger stale rollback. New-capability cache reconciliation verifies
the durable nonce; legacy helpers retain their existing fail-closed behavior.
The original protected-commit reply and four-field request contract remain compatible.
Older ProtectedTunnelControlling ports reject unsupported receipt lookup explicitly.

## Evidence and boundaries

Production helper RPC/controller, coordinator and PSK app cutover bodies execute
with inert network ports. A real disposable Unix socket tests kernel peer forwarding;
positive identity injection is NOT production code-signing acceptance. A separate
real temporary-directory test executes production atomic writer and private reader,
not a permissive in-memory filesystem. Frozen evaluator inputs are identical across
BASELINE, MODIFIED and ROLLBACK source copies; literal stdout/stderr/exits are retained.

A receipt persists through helper runtime reconstruction, not permission to adopt a
dead process or arbitrary cached profile. Durable app-side pending intent/cache
reconciliation and explicitly authorized app-crash ownership transfer remain unfinished
(coordinator TODO retained). Actual OS-crash/power-loss acceptance is also unproven:
fsync/offline tests do not prove full hardware ordering. See Apple's fsync manual:
https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html

No installed helper/app, live route/DNS/PF state, private signing key, deployment or
publication is touched. Isolated Mac install/connect/update/crash/power-loss and
actual Developer ID/console-UID acceptance, notarization/deployed signer attestation
and remaining Android parity are separate pending release gates.

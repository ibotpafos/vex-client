# Cycle 31 — durable app-side protected promotion metadata

## Implemented operation

`NativeProtectedPromotionStore` extends the existing descriptor-anchored
`NativePushSecureFileStore`. One account/installation namespace has one bounded
16 KiB, owner-only intent record under the app-private `push-psk-events` directory.
The filename is a length-prefixed ownership fingerprint. Contents are canonical
JSON nonce/source/candidate/owner hashes, process-instance ID, intent fingerprint,
VPN generation and optional confirmed receipt. No config, private key, raw account
identity, access token or helper owner token is copied to this record.

The actual app PSK cutover writes the original intent before staging/replacement,
writes uncertain state before commit RPC, and retains the authenticated physical
candidate if a post-commit metadata or cache write fails. A reconstructed coordinator
uses the same nonce and exact root receipt; it cannot repeat replacement or reconnect
just because its in-memory receipt disappeared. Cache promotion occurs before intent
removal. Removal failure retains evidence for an authenticated cache-only retry.
Existing metadata cannot be silently replaced with a different scope or transaction.

The intent binds the full source/candidate value representation (hashed in memory),
account, installation, session/token, helper identity, selected/target location,
routing and original VPN generation. Every async boundary and the helper independently
revalidate current intent/owner. Unknown/duplicate/noncanonical, oversized, stale,
different-process, wrong-owner/hash and changed-during-proof records fail closed.
Canonical key ordering uses Foundation's documented sortedKeys option:
https://developer.apple.com/documentation/foundation/jsonencoder/outputformatting-swift.struct/sortedkeys

The generic helper wrapper/coordinator keeps optional persistence for older callers;
those existing memory-only contracts remain tested. Durable PSK promotion requires
the receipt capability and fails closed on an older helper; it never falls back to
ordinary up/down/reconnect. Explicit account cleanup deletes only its owned metadata
namespace. Session invalidation does not turn retained metadata into admission.

## Executable evidence

The new evaluator compiles the production coordinator, promotion store and secure
filesystem with literal inert RPC/config ports and a real disposable private directory.
The PSK evaluator executes the actual app cutover and helper wrapper, including cache
failure followed by coordinator reconstruction. No app launch, installer, API, APNs,
Keychain, live route/DNS/PF or unowned process is reachable from these fixtures.
Frozen evaluators are identical across BASELINE/MODIFIED/ROLLBACK source inputs.
Literal commands/stdout/stderr/exits and source/rollback/build hashes are in the four
permanent transaction roles, not inferred from source text.

## Remaining release gates

Sensitive source/candidate material and app scope closures remain memory-only.
Metadata alone does NOT recover a dead process's admission or authorize owner transfer.
Full app-crash material reconciliation and explicitly authorized cross-process recovery
remain unfinished at the coordinator/app TODOs. This is not complete app-restart or
OS-crash/power-loss acceptance. Atomic writes/fsync are not proof of hardware ordering:
https://developer.apple.com/documentation/xcode/reducing-disk-writes

An isolated Mac is still required for install/connect/update/crash/power-loss and real
code-signing/console-UID acceptance. Developer ID/notarization, deployed signer attestation
and remaining Android parity are separate pending gates. The existing active VPN remains
untouched; no production deployment, release publication or private signing key is used.

# Cycle 37 — opt-in pre-stage client consent (offline only)

The Settings toggle is process-only and off by default. APNs, launch and status
cannot opt the user into ownership-transfer consent. Logout/push withdrawal
clears the toggle. Turning it off does not discard an unresolved transaction or
fall back to a legacy replacement; explicit original-owner cancellation remains
separate. The legacy no-consent contract remains supported when never selected.

`NativeProtectedReplacementCoordinator.replace` retains a canonical optional
`stageConsentPending` field before config staging. Nil preserves old encoding;
true means this client has not sent replace, false cannot move back to true.
Lost authorize ACK retries only the same nonce/scope/generation and capability,
not a fresh snapshot, material reconstruction or an extended local TTL.

`VEXAppState.nativePSKStageConsent` consumes exact memory-admitted source and
candidate bytes. The existing private material/capability custody is reused ONLY
for the same root journal/receipt restart bridge. A separate canonical bounded
`stage-consent-*` purpose/ACK record prevents post-journal authorization from
renewing a pre-stage capability. It is not admission or takeover authority.

The actual helper wrapper owns busy and passes its authenticated send port into
the callback. No nested busy wrapper, generic connect, installer or owner adopt
is used. Material and one-use capability are durably read back BEFORE the stage
RPC. Signed stage, current account/install/device/public key, policy, generation,
selection and desired state are rechecked across async boundaries. Unknown,
denied, malformed, missing or unsupported ACK is a hard failure, not fallback.
Root C36 still pins the capability/candidate to its one-use authenticated grant;
the replace RPC has no new raw-capability argument.

Explicit cancellation uses the separate root cancel-stage verb only for exact
original-process custody. A durably retained cancellation ACK allows retrying
private cleanup without another RPC, admission or network operation. Consumed
journals/receipts cannot be removed by the unconsumed-intent cleanup method.
Successful candidate promotion uses independent authenticated receipt proof
before cache/private cleanup and removes capability/material before the nonce.
Cleanup/cache retry revalidates the exact receipt; it does not adopt/replace or
commit again. Existing C35 source replay fences remain in place.

## Observed fixture scope

- New 44-case compiled AppState cutover/factory/helper/coordinator/custody matrix:
  explicit opt-in and legacy compatibility; strict reply faults; lost-authorize
  ACK same tuple/capability; conservative expiry; current changes after authorize,
  commit and receipt; cancellation; cache/private cleanup retry; strict purpose
  file mode/unknown-field/symlink/hardlink denial. All RPC/config ports are inert.
- Retained actual root/runtime 86-case C36 test, owner-transfer70, client68,
  signed material27/App39, journal115 and ordinary cutover53 assertions.
- Identical frozen evaluators are run against baseline, modified and separately
  rolled-back copies. The new contract is ABSENT on the C36 baseline: one honest
  diagnostic/exit1, not execution of nonexistent branches. Modified is exit0.
  Exact commands/stdout/stderr/statuses and hashes live in the four-role ledger.

## Explicitly unfinished

`TODO(stage-cancel-lost-ACK)` remains at the exact client boundary: root C36
cancellation deletes its consent and has no durable cancellation tombstone. If
the ACK or client ACK-marker write is lost, the client retains inert custody and
does not claim cancellation, renew consent or downgrade. The next cycle must
provide exact original-live-owner idempotent root cancellation proof and verify
it across crash/write boundaries. Orphan consent and expiry remain fences.

Actual OS crash/power loss, console UID/signing, installation, tunnel connection,
updates and leak tests still need an isolated Mac/VM. Offline universal packaging
and ad-hoc signatures are not Developer ID/notarization or release approval.
No live VPN/routes/DNS/PF, installed helper/app, private signing keys, original
live checkout or production mutation is part of this cycle. Android parity and
the release goal remain ACTIVE, not complete.

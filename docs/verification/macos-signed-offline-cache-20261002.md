# Signed normal offline cache — isolated candidate, not released

Cycle21 extends the actual normal resolver, not the PSK staging state machine.
`VPNProfileService.resolveProfile` can reuse only an owned cache record containing
the original signed authorization, existing installation identity and existing
matching private/public client key. It reverifies the pinned signature, exact
account/device/install/client key/epoch/request/routing/version/tunnel fields and
expiry, then rerenders locally. Cached config, fetchedAt and unsigned bypass data
cannot supply authority. Signed issued-at must be no older than 300 seconds.
This is a bounded offline stale-authority allowance, not proof of immediate
remote revocation or a full-record rollback/replay prevention guarantee.

The backend candidate signs optional `client_public_key`, `client_key_epoch` and
`installation_id` from actual service/device metadata. Existing policies omitting
all three remain valid for fresh normal admission and staged PSK compatibility,
but never for offline normal reuse. Partial/mismatched signed bindings fail closed.
Legacy/staged cache records decode with optional normal proof absent and miss the
normal fast path. Automatic empty request and explicit `de` occupy distinct keys.

Force-refresh bypasses offline reuse. Missing/invalid/expired/revoked/mismatched
proof is a miss requiring a complete fresh response, never a timeout or routing
fallback. Current session guards apply before optional helper write and after
suspension. Logout/session reset and known access/revocation block owned reuse
before owner-scoped deletion; deletion failure cannot mask subscription/revocation
domain errors. Deletion refuses symlink ancestry (not a hostile concurrent
filesystem-race audit). It never changes helper, current tunnel, keys or endpoints.

Offline evidence uses actual extracted production methods, models, CryptoKit,
AWG admission, and D-scoped/inert ports: first signed response saved; second same
scope returns a local-key-rendered config with zero profile fetches. 18 normal
admission rejects plus 28 cache negatives, force-refresh/currentness/removal-error
checks and actual filesystem model roundtrip/scoped removal are required. The
immutable pending legacy fixture remains a recorded exit1; a separately qualified
fixture adds synthetic signed client/install fields and preserves the acceptance.
Same qualified prior/current/executable-restored gate must observe 1/0/1, with
exact original source hashes/modes and patch reconstruction.

Still unfinished: ordinary APS-only authenticated profile reconciliation and
cache invalidation; durable registration recovery; full routing/recovery parity;
deployed signer/public anchor attestation; Developer ID/notarization and separate
Mac install/connect/update/APNs/leak acceptance. Server changes are not deployed,
so production fresh profiles without the new signed binding remain offline misses.
No app/helper installation/launch or live VPN/API/DB/APNs/route/DNS/PF mutation.

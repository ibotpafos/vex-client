# Native macOS crypto wake-up atomicity and normal signed-profile boundary

## Implemented and offline-proven

- `RotateDevicePSK`, `RegenerateDeviceKeys`, and `RotateManagedDevicePublicKey`
  insert the existing canonical native lifecycle outbox event in the same SQL
  transaction as their device/token/job/audit changes, before COMMIT. A failed
  event INSERT returns zero result and requests rollback. Managed-key changes
  now capture the registration under the device FOR UPDATE lock. A locked
  operation replay recheck avoids another mutation/event after concurrent success.
- New events have generated ID, pending state, zero attempts, no lease/sent/error,
  saved owner/provider/revision, resulting persisted profile version, NULL rotation
  ID, and `key_rotated` reason matching the ordinary managed-key callback.
  Legacy FCM and missing registration do not acquire a native outbox dependency.
  The automatic PSK scheduler remains disabled; no live rotation is enabled here.
- The store's new SQLmock matrix exercises all three mutation methods, including
  success, event INSERT failure, mutation/audit/user failure, commit error,
  FCM/unregistered compatibility, and replay after locking. SQLmock is not live
  PostgreSQL concurrency, persistence, migration or ambiguous-COMMIT acceptance.
- `verifyNormalProfile` verifies a normal signed policy without PSK IDs. It binds
  account/device, outer version/device, original requested and assigned location,
  routing/region/policy version, expiry and exact tunnel fields. Unsigned opaque
  config and outer bypass metadata are stripped; signed MTU/keepalive are returned.
  The CLI synthetic P-256 matrix verifies success and rejection branches. Existing
  staged-PSK verifier checks are retained separately.

## Important correction and unfinished acceptance

The server's existing normal managed-native response can already carry optional
`authorization` when its configured signer is available. It is not accurate to
describe all normal server responses as unsigned. The native persistence path
currently does **not** invoke the normal verifier; its config/cache/helper admission
is still unfinished. A concrete TODO remains at `persistManagedProfile`, and the
next frozen fixture targets invalid-proof rejection before cache/helper writes.
Do not infer ordinary authenticated push reconciliation or safe promotion merely
from the pure verifier matrix passing.

Revoke/move/profile repair still require atomic event/reconciliation boundaries.
Arbitrary late registration POST/lost receipt, domain/per-app routing and recovery,
production public-key matching, APNs/Developer ID provisioning, Xcode XCTest and
separate-Mac install/connect/update/leak/long-network acceptance remain. A COMMIT
error has an unknown real database outcome until reconciled. No production action,
live DB/APNs call, application/helper launch, installation or VPN/route/DNS/PF
change is permitted by these offline tests.

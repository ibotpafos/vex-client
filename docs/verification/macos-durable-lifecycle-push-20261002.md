# Native macOS ordinary lifecycle push: durable backend entry (cycle 18)

This is an isolated offline candidate, not a public release or deployed server.
The current active VPN is not installed, stopped, replaced or reconfigured.

## Implemented paired-server change

- Ordinary native macOS managed/client-owned AmneziaWG APNs profile notifications
  enqueue durably and synchronously before asynchronous provider slots/delivery.
- The registration is locked and compared by device, owner, provider, canonical
  token, persisted revision and profile version; stale callers cannot rebind.
- A generic lifecycle row has a NULL rotation ID; it retains device/rotation
  foreign-key and existing unique constraints. Existing claim/retry/settlement
  machinery processes it, rather than a new observer/polling service.
- Only active `profile_updated` and explicitly revoked `device_revoked` native
  targets are accepted. Other inactive/event pairs fail closed. Revocation wakes
  account invalidation only; a push never carries or applies VPN configuration.
- Provider errors use the existing revision/claim-fenced terminal rejection and
  transient retry policy. Legacy FCM bounded asynchronous delivery is retained.
- Generic APNs payload remains APS-only for deployed/native decoder compatibility;
  no fabricated PSK rotation ID/event is emitted.

## Evidence and limits

The saved c481dc entry gate actually returned exit 1: durable enqueue 0, direct
notifier calls 1. Its fake omitted persisted ProfileVersion while asking for
version 1. The separate transaction fixture qualifies that input by adding only
captured ProfileVersion 1; product validation is not weakened. The same qualified
fixture must run against original, modified and executable-restored server copies.
Expanded entry/delivery/SQLmock matrices and literal command/exit logs accompany
this candidate. SQLmock is not production PostgreSQL or APNs acceptance.

The existing void callback cannot atomically join the profile mutation with the
outbox insert: an enqueue failure after mutation still needs proper rollback or
reconciliation. Concrete TODOs remain at both mutation notification boundaries.
The native APS-only receiver refreshes account/PSK state but does not correlate
an ordinary signed-profile replacement. Its code TODO explicitly requires an
authenticated, session-bound signed fetch; no automatic push-payload application.

Developer ID/APNs provisioning, current server public-key attestation, full Xcode
XCTest and isolated signed installation/connection/update/long-network/leak tests
remain release gates. No server deployment/migration, live delivery, native app or
helper launch, user Keychain access, or route/DNS/PF modification occurred.

# IBO-159: staged AmneziaWG PSK client

## Objective

Apply a server-rotated AmneziaWG preshared key without switching the native
tunnel before the server peer has completed its fenced cutover.

## Scope and contract

- Android records `profile_updated` and `cutover_ready` FCM data events in a
  durable, deduplicated native queue and exposes them to the authenticated JS
  runtime.
- On `profile_updated`, the client fetches the owner-scoped inactive profile,
  validates the event/response identity and version, durably stores the
  material, and only then acknowledges its digest.
- On `cutover_ready`, the client activates only the exactly matching staged
  profile. A missing/mismatched staged profile leaves the current tunnel intact.
- Replayed events and retries are idempotent. Failed fetch, persistence, ACK, or
  activation keeps enough state for a later retry and never discards the current
  working profile.
- Automatic server rotation and production deployment remain outside this
  client change.

## Scenarios

1. Online: queue -> fetch -> durable stage -> ACK -> ready -> activate -> clear.
2. Offline/asleep: native queue retains the event until authenticated resume.
3. Retry: repeated update reuses the same rotation; repeated ready activates at
   most once.
4. Stale/cross-device: event is rejected without fetch, ACK, or activation.
5. Failed activation: staged material remains and the current profile remains
   selected.

## Acceptance criteria

- Unit tests prove persistence-before-ACK, exact matching, replay behavior,
  activation-after-ready, and retention after activation failure.
- Typecheck, lint, unit tests, and Android Kotlin compilation pass.
- No WireGuard runtime or profile is introduced; all user-facing terminology
  and the transport contract are AmneziaWG.

# IBO-172 native realtime reliability

## Objective

Keep customer state current on Expo, macOS, and Windows when the SSE stream is
healthy, rejected, half-open, or unavailable, without changing the desired VPN
tunnel state.

## Scope and contracts

- HTTP 401 is equivalent to `customer.session.revoked`: refresh the session once
  and sign out if refresh is rejected.
- A stream that delivers no bytes within the liveness deadline becomes
  disconnected and reconnects with bounded backoff.
- All SSE line endings (`LF`, `CRLF`, and `CR`) are accepted.
- Heartbeats only prove liveness; they never trigger expensive state refreshes.
- macOS customer state and the Windows account page use coarse polling only
  while realtime is disconnected.
- Refresh operations are serialized or coalesced so bursts cannot overlap.

## Scenarios

1. A valid event marks realtime healthy and refreshes only its customer domain.
2. HTTP 401 runs the same auth lifecycle as a session-revoked event.
3. A half-open stream misses its deadline, disables realtime health, and
   reconnects while fallback polling resumes.
4. Repeated heartbeats reset liveness but do not refresh account/settings data.
5. A disconnected native client eventually refreshes customer state by polling.

## Invariants

- Realtime and fallback refreshes do not connect, disconnect, or restart VPN.
- At most one fallback/customer refresh per surface runs at a time.
- Event payloads remain metadata-only.

## Acceptance criteria

- Unit tests cover 401, CR separators, watchdog expiry, event filtering, and
  reconnect delay.
- Expo checks, macOS target build/parser harness, and Windows core tests pass.
- Windows WinUI and macOS XCTest remain explicit platform-CI gates when their
  toolchains are unavailable on the current host.

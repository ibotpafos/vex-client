# IBO-87 — AWG3 endpoint fallback and self-recovery

## Objective

Keep one-button VPN connection reliable when an AWG3 port or node stops handshaking, without ever downgrading to AWG2 or creating a reconnect storm.

## Scope

- React Native watchdog recovery scheduling and same-location profile refresh.
- Native macOS endpoint fallback parity.
- Contract verification against the server's live-health-aware same-location AWG3 profile selection.
- No production deployment, server mutation, credential use, or AWG2 compatibility path.

## Scenarios

1. A handshake fails on the current endpoint: the client tries only the bounded AWG3 ports `51821` and `443` with the existing per-attempt timeout.
2. All ports for the current profile fail: recovery force-refreshes the same location so the server can return a healthy second AWG3 node before trying another location.
3. Repeated watchdog recoveries fail: exponential backoff with jitter delays retries and a circuit breaker opens after the bounded failure threshold.
4. Recovery succeeds: failure state and the circuit breaker reset.
5. The last successful endpoint is reused only through the existing TTL-bound hot-profile cache.

## Invariants and contracts

- Automatic recovery requires the AWG3 `HeaderProtectionKey` contract and never synthesizes port `51820` as a fallback; a server-signed AWG3 primary may retain its configured port.
- Each native connect attempt remains bounded by `connectAttemptTimeoutMs` and handshake verification.
- Recovery diagnostics contain reason/outcome and endpoint metadata only; they do not add user IPs, keys, or raw configuration.
- Manual location choice changes only when recovery exhausts same-location options and succeeds in another location.
- Server profile refresh remains fail-closed when no live AWG3 node exists.

## Acceptance criteria

- Unit tests prove bounded backoff, jitter bounds, circuit-open behavior, and reset after success.
- Client recovery test proves current same-location profile failure followed by a force-refreshed second endpoint success.
- Server tests prove an offline mapped AWG3 node selects a live same-location node and no-live fallback fails closed.
- macOS and React Native fallback tests prove that `51820` is never synthesized as a fallback.
- Targeted tests, client typecheck, diff check, rollback-copy verification, commit, push, PR, and Linear evidence complete successfully.

## Native CI closure

- Every recovery change triggers shared TypeScript, Android/JDK, and macOS/Swift jobs on pull requests and `main`.
- Android CI runs `VpnNetworkRecoveryTest` on a clean runner with the pinned AmneziaWG bootstrap.
- macOS CI compiles the package and runs `NativeParityModelTests` on a hosted macOS runner without release signing.
- Release-only signing and publishing remain restricted to explicit production workflows.
- Workflow conditions must parse before runner allocation; job-level conditions do not reference the `secrets` context.

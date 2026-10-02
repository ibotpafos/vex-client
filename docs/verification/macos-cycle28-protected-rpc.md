# macOS protected profile transactions — offline scope

Cycle 28 adds `protected-snapshot`, `protected-replace`, `protected-commit` and
`protected-recover`. The authenticated socket peer must match the saved live
owner PID, process-start identity and owner-intent token. Snapshot grants are
short-lived and single-use; exact source/candidate digests bind the journal.
Private configurations and keys are not command arguments or responses.

The helper keeps anti-leak protection armed across replacement and protected
source recovery. Commit requires an uncached exact candidate state and a fresh
handshake after the cutover floor, newer than the source handshake. An uncertain
journal still fences ordinary up/down/shutdown/watchdogs. The application uses
the dedicated coordinator, never generic reconnect as a rollback substitute.

Normal signed-profile changes and connected PSK rotation use this coordinator.
A post-commit PSK cache failure retains the confirmed candidate and receipt for
authenticated cache-only retry in the **same application process**. Consent
revocation and session invalidation clear that in-memory promotion state.

## Verification

`scripts/test_native_macos_offline.sh` includes the authenticated runtime,
coordinator, pending-normal-profile, PSK cutover and consent/intake regressions.
`scripts/tests/test_macos_protected_rpc.py [SOURCE_ROOT]` is also suitable for an
identical frozen baseline/modified/rollback evaluator when its sibling
`test_macos_protected_replacement.py` is frozen with it.

The socket regression uses the production `UnixSocketServer` and kernel peer
credentials with memory-only filesystem, tunnel, DNS, route and PF ports. It
checks dedicated commit/recovery, malformed frames, replay, pending fences,
server/runtime authentication rejection and foreign ownership. Its positive
peer policy is injected and restricted to its unprivileged parent. The actual
system policy rejects this non-production fixture; this is **not** evidence that
a Developer-ID-signed production app will be accepted.

## Still required before release

- Preserve exact canonical admitted source bytes across normal connect and
  protected commit; do not resolve an old source hostname a second time or
  trust arbitrary helper snapshot digests as signed-profile authorization.
- Reconcile durable commit receipts, ambiguous replies and explicitly authorized
  process-ownership transfer after application crash/restart.
- Isolated installation, connection, update, crash/power-loss and anti-leak
  acceptance, plus actual code-signing/console-UID acceptance.
- Developer ID signing/notarization, deployed public-profile-signer attestation
  and the remaining Android parity/release acceptance.

Offline artifacts must not be installed or published as a release. No test may
signal the installed helper, disconnect the active VPN or mutate live routes,
DNS or PF. Only the retained disposable fixture child may be terminated.

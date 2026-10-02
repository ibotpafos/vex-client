# macOS cycle 29: confirmed source-byte binding

This is an offline candidate, not a public release or installed-runtime result.
The original checkout and the running VPN are not modified.

## Production change

`VPNProfileService.writeHelperConfig` returns the exact canonical bytes written
through existing AWG admission. After a verified normal-connect handshake,
`VEXAppState.connectPreparedTunnel` requests an authenticated protected snapshot
and accepts only a locally expected SHA-256. A denied proof does not disconnect
an otherwise verified normal connection; it leaves protected cutover unavailable.

`NativeAdmittedProfileStore` keeps those bytes in memory, with full prepared
profile equality, account, existing installation, authenticated session generation,
weak helper-object identity, revision, and confirmed helper owner-intent digest.
It is never populated by cached UI status, an arbitrary helper hash, or restart
reconstruction. Session invalidation and route-state cleanup erase the binding.

`processNativeNormalPendingProfile` and `applyNativePSKCutover` use the stored
source bytes and expected owner digest. Only the candidate is sanitized/resolved.
The authenticated coordinator rejects changed owner intent before config staging.
Successful commit records the candidate bytes for the next cutover. A post-commit
PSK cache failure retains the candidate binding and exact receipt for cache-only
retry; invalidation fences that retry. Protected source recovery uses the original
bytes and does not invoke a generic reconnect.

## Offline regression evidence

All RPC/config/network boundaries in the app fixtures are inert. Production app
methods, helper wrappers, coordinator and memory store are compiled and executed.
The same frozen evaluator can run against baseline, modified and rollback copies.

- PSK: 41 cases; the old baseline has 6 failing new regressions, modified has 0.
- Normal pending driver: rotating DNS and missing-admission fences are false in
  the old baseline and true in modified; historical signed/current-scope tests pass.
- Normal admission/store: 25 modified cases, 0 failures, including exact written
  bytes, denied/mismatched/duplicate/unterminated/pending proof, stale session/token/
  installation/intent, profile/helper/revision scope and malformed record rejection.
- Authentication generation and pending-transaction fences remain enforced.

Compatibility storage and empty admission ports in frozen legacy fixtures allow
old production method bodies to execute; they do not fabricate successful
admission. Source tests do not establish actual Developer ID/console-user acceptance.

## Release limitations

Bindings and post-commit cache receipts are memory-only. Durable crash recovery,
ambiguous replies and explicitly authorized ownership transfer remain unfinished
(the coordinator TODO is retained). No installed app/helper or live route/DNS/PF
operation is run. Installation, real connection, update, power-loss/crash and
production-signature acceptance require an isolated Mac. Universal packaging is
ad-hoc only; Developer ID, notarization and public-signer/deployed release
attestation remain separate gates. Android parity is not declared complete.

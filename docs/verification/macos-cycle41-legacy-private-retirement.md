# macOS cycle 41 — legacy private cleanup and normal-admission wire contract

Scope: the same offline release-readiness candidate. No installed app/helper,
normal connect, service restart, routes, DNS, PF, production or release changes.
The enabled VPN must remain untouched. Ad-hoc packages are not public releases.

## Verified implementation

- `NativeProtectedReplacementCoordinator.verifyAdmittedSource` accepts the exact
  current healthy root snapshot: protocol, pending=false, source hash, owner hash
  and receipt protocol; **no transaction ID**. The previous six-field contract
  and five-field/no-receipt legacy NORMAL-admission contract remain compatible
  only with a canonical UUID. Legacy admission never grants receipt support or
  terminal retirement on an old helper. All three formats reject unknown,
  duplicate, missing, malformed and non-current replies. No UUID is invented.
- A pre-WAL legacy nonce absence is only a condition, never authority. Material,
  original/transferred intent and source-restoration fence must still match.
  Present capability/purpose custody must be canonical and owner-scoped; expired
  capability bytes can be cleaned, not renewed. Missing material with remaining
  private custody fails closed without reconstruction.
- Only the actual explicit newly signed normal-admission caller can enter the
  bootstrap. Its current memory admission, account/session/install/helper,
  operation generation, desired state, current device and key/epoch are fenced.
- `reconcileLegacyPromotionRetirement` obtains **two fresh authenticated
  read-only root snapshots after that new admission**, comparing the new profile
  and owner hashes and all private custody before/after each await. No mutation,
  adoption, transfer, reconnect, capability generation, TTL, cache or ACK port.
- `PromotionRetirement.kind = normal-admission-legacy-no-nonce` is a dedicated
  bounded canonical 0600 variant. `nonceSHA256 = nil` is valid only for it; old
  variants retain their exact required nonce digest and canonical bytes. Older
  readers reject this new variant rather than silently infer authority.
- Write/read back terminal WAL **before** any private deletion. A reappearing
  nonce or changed remaining custody vetoes cleanup, including explicit retry.
  Exact source replay fence remains through private-only retry/secret loss and
  is cleared last only by an actual NEW normal signed/root admission. Inactive
  staged profile/event custody is not admitted or erased by source cleanup.

## Evidence and scope boundaries

Focused compiled checks cover 84 legacy App/helper/store/owned-file scenarios,
plus 56 separate normal-admission wire checks covering the current and both
previous formats. The actual helper/coordinator methods run with deterministic inert
authenticated root reply ports; no installed socket or ordinary connection is
executed. IO exceptions plus fresh store objects are not OS crash/power-loss or
current-console-UID acceptance. The existing 131 retirement scenarios preserve
the before-admission absence denial and now require explicit legacy success
only after the new normal admission plus two fresh proofs.

Commands, literal outputs, failed attempts, source/package hashes and frozen
baseline/modified/rollback results are retained in the permanent four-role
transaction under `/Volumes/D/Projects/mobile/macos-release-transaction-20261001`.
Final aggregate/package/rollback status must be taken from the C41 effective
result and command records, not inferred from this document or passing fixtures.

## Unfinished release work

`TODO(protected-current-snapshot-intent)` remains at the initial NEW protected
cutover's literal `transaction_id` branch: the current healthy root snapshot
does not allocate a client nonce. That path still fails closed and needs exact
root/client cross-contract verification plus one-use new-intent persistence;
never reconstruct a missing old legacy nonce. Source/recovery journal and root
receipt/pre-stage cancellation authority are unchanged in cycle 41.

`TODO(post-promotion-legacy-platform-QA)` requires a separate Mac for actual
legacy crash/power-loss, AF_UNIX, current-console UID and install/connect/update/
leak acceptance. Developer ID/notarization, APNs provisioning/deployed signing
attestation and final full Android parity/release acceptance remain outstanding.
The full user goal remains active.

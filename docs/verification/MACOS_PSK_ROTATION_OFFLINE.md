# Native macOS PSK rotation: offline source qualification

Target: `/Volumes/D/Projects/mobile/vex-client-release-readiness-20261001`.
Original mobile/server checkout and installed applications are not modified. No app/helper
was launched, no live API/APNs/Keychain/preferences operation was used, and the protected
INCY VPN, routes, DNS and PF are outside every fixture.

## Actual source path

`receivedNativeRemoteNotification` durably admits metadata only. The authenticated
`processNativePSKEvents` serial consumer scopes every async boundary to account, installation,
managed device, session/token generation, VPN-operation generation, selected location and
routing mode, explicit push consent/capability, idle operation state and paid access.

1. Fetch or reload the exact inactive rotation envelope.
2. Verify original P-256/SHA-256 ASN.1 DER signed policy against immutable bundled public keys.
   Verify owner/device/version/location/expiry and signed tunnel fields. Derive MTU/keepalive
   directly from signed data. Compare the outer client public key with the existing local
   keypair (that client key is **not** itself cryptographically included in the server policy).
3. Check the server's ordered Go JSON SHA-256 digest, /32 address, keys, DNS/routes and deadline.
4. Build only in memory and run existing **pure** `VEXHelperCore.AwgConfigAdmission`; do not
   create/rotate/migrate keys, resolve DNS, write helper config or promote the active cache.
5. Record the owner tuple index before secret write, persist the original signed proof and
   inactive profile, reload exact equality, verify again, then ACK the exact version/digest.
6. Remove `profile_updated` metadata only after accepted matching ACK. Retain signed stage
   for restart/cutover. Out-of-order cutover remains queued for retry.
7. Reverify before cutover. Confirmed idle promotes cache/profile only; connected cutover
   replaces only our matched active tunnel, uses only the signed endpoint, verifies handshake,
   retains anti-leak on failure and attempts guarded rollback. Stale tasks perform no cleanup.
8. Successful activation removes cutover metadata before stage cleanup, preventing duplicate
   activation on a cleanup failure. Owner tuple index remains authoritative for logout/disable
   cleanup after metadata ACK. Index/data corruption is preserved and fails closed.

## Limits that remain release blockers

- The existing Windows release public keyring was found in
  `native-windows/packaging/profile-signing-keys.json`, introduced in commit
  `6fa856ceff073ff356b5df5e67d33401297cb28e`. Its source SHA-256 is
  `be66fbec7816879c8cb6bb36fa8947263b53c3cc9f829d969361776163896ec1`;
  key ID is `native-profile-p256-v1` and SPKI DER SHA-256 is
  `f194a1a8765d9e5490ade0f5f6df7310e187d8a5f2baeddf39eee0165c4c2289`.
  This is repository/release-pipeline provenance, **not** independent attestation of
  the currently deployed server key. No private key was read or derived.
  An offline candidate may explicitly reuse this public repository anchor; publication
  still requires matching an approved current-server fingerprint/release attestation.
- `VEX_NATIVE_VPN_PROFILE_PUBLIC_KEYS_FILE` explicitly supplies the dictionary resource
  `{ "KEY_ID": "standard-base64-SPKI-DER" }`, <=8 P-256 keys / 64 KiB. The builder
  uses one bounded nonblocking/no-follow regular-file FD read, rejects duplicate IDs
  and noncanonical Base64, validates **copied bytes** with platform CryptoKit, then
  signs the bundle. No input means no resource and the verifier remains fail-closed.
  Never bootstrap trust from a profile response or copy fixture keys into a release.
- Current backend staged policies omit routing metadata and sign a full tunnel. Legacy full-tunnel
  proof is recognized; it is never relabelled as split/smart routing. Signed split-routing staging
  remains a source TODO and requires a compatible backend contract plus focused regression proof.
  The actual requested `all_except_ru` + `ru` signed-stage chain gate exited 1 with
  `FAIL: stage reload ACK`; it did not ACK or activate the mismatched policy. Merely adding
  routing fields is insufficient: the server currently has no persistent device-routing
  preference. An authenticated pre-prepare negotiation must snapshot routing claims,
  preserve the prepare/fetch digest, and keep legacy rotations compatible. Android's
  legacy smart setting maps to `all_except_ru`; no separate `smart` mode is established.
- MainActor serialization is not a cross-process file CAS. FD-store sync/mapping defenses are not
  a blanket same-UID attacker or power-loss guarantee. Such stronger acceptance is unproven.
- Native APNs token CAS/order/unregister, provisioning/signing, enforced per-app routing, extended
  throwing recovery, full Xcode XCTest, isolated signed install/connect/update/APNs/permission
  acceptance, notarization and approved publication remain unfinished. No test Mac/VM is available.

## Offline evidence scope

Standalone fixtures compile actual production types and/or unchanged production method bodies;
helper/API/cache collaborators are explicitly inert where required. Go signs disposable fixtures
and generates server-order digests. Runtime fixtures cover signature/owner/tuple/digest rejection,
durable staging-before-ACK, restart, queue failure/retry/reentrance/out-of-order events, exact-owner
secret cleanup, signed-value preparation and guarded idle/connected/stale/rollback cutover.

`test_native_macos_offline.sh` includes these gates; aggregate/universal/package/source-copy rollback
results are recorded only after their observed terminal events in the native transaction ledger.
No unit or compiler check is a claim of installed/live VPN or APNs acceptance.

## Search-first decision

Reuse native CryptoKit, existing FD store, API client, client key store, parser and Android event
ordering; add no external dependency or alternate signing implementation. Apple references:
[CryptoKit P256 public key](https://developer.apple.com/documentation/cryptokit/p256/signing/publickey),
[CryptoKit DER signature](https://developer.apple.com/documentation/cryptokit/p256/signing/ecdsasignature),
[Apple Swift Crypto](https://github.com/apple/swift-crypto). The browser fetched JavaScript wrappers;
Markdown extraction returned HTTP-tool 400. API behavior here is proven by the local SDK and real
Go-generated-signature/Swift-runtime fixtures, not by unread page content.

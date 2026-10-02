# macOS normal signed-profile admission — offline cycle20

Candidate source baseline: 7f843577b63d42475892a6894ad20eef787dae59.
Backend dependency retained at 9fc055605f0d409cfc9f378a878d9874862482ea; not deployed.

## Executed finding and repair
The atomic frozen runtime actually ran the production persistManagedProfile body:
invalid_signed_normal_profile rejected=false cache_writes=1 helper_writes=0; exit1.
It accepted unsigned opaque config merely because it contained [Interface]/[Peer].

Normal persistence now uses NativeVPNProfileAuthorizationVerifier.verifyNormalProfile with captured account, managed device, exact normalized request, effective route/region, and positive response version. Assigned location is returned from the verified policy: there is no assigned-location outer API field. Empty requests are supported by the existing server (policy requested_location_id omitted); they must not be guessed as de/hostname/label.

Only verified tunnel fields are rendered, with the already-owned local private key and signed MTU/keepalive. Derived Curve25519 public key must match stored key, authenticated managed device public key, response client public key and epoch. Opaque config/unsigned bypass metadata are ignored. Actual AwgConfigAdmission validates rendered output. This is NOT a claim that outer client-key fields themselves are signed, nor proof of current production signer matching the packaged anchor.

All real AppState resolver/rotate/helper-write callers pass captured synchronous session/current-VPN guards. Resolver checks before identity/key mutation, after each awaited stage, before cache/helper mutation and after helper sanitizer suspension. Production identity registration also checks before challenge/signing/register continuations. No app/helper/live API/Keychain/preferences/cache/VPN operation was run in testing.

## Intentional compatibility/security limitation
Normal cache contains no verifiable signed envelope. Freshness/account scoping alone is not authorization. Normal cache-hit, known-version unchanged, timeout cache fallback and implicit route-changing fallback are disabled. Complete signed responses are requested. Last admitted config is stored for current candidate state, but cannot be used as a reconnect admission proof. Safe signed cache persistence/reverification/offline reuse is unfinished and marked TODO next to resolveProfile. This is a deliberate fail-closed regression in offline availability, NOT full Android parity or release completion. Staged PSK promotion/preparation retains its independent verified path.

## Observed scoped verification
Actual extracted persistence + renderer + model/verifier/CryptoKit + AWG parser, with inert ports:
- Valid signed config rendered local key, signed MTU1420/keepalive55; cache1/helper1.
- Eighteen rejection cases: missing/invalid proof/anchor, account/device/version, client key/epoch/private-key binding, revoked/unchanged, requested location, expiry, stale entry/pre-cache session; cache0/helper0.
- Actual helper write body blocks stale session after sanitizer suspension; already-valid earlier cache1, helper0. Cache failure prevents helper write.
- Actual resolver requests normalized full signed response, knownVersion=nil, ignores seeded legacy cache; timeout/provision failures in both routes produce one API-port request, no cache/helper writes and no route change.
- Session changes after entitlement/device/profile await yield no writes; obsolete entitlement stops before key creation; missing account stops before identity/key/API ports.

The frozen fixture is retained unchanged. Its transaction-qualified copy only adapts body extraction past new default closure, imports/errors/renderer signature and includes actual read-only AWG parser. Original schema/extraction failures are retained. Same qualified acceptance must run baseline/modified/executable-restored 1/0/1.

Full Xcode XCTest, installed signed update/connect/APNs/long-network/leak acceptance remain unverified. No spare Mac/VM. Universal build/public gate evidence is recorded separately; ad-hoc DeveloperID failure is not public release acceptance. INCY must remain connected.

Existing maintained solutions reused; no dependency installation:
- https://developer.apple.com/documentation/cryptokit/p256/signing/publickey
- https://www.wireguard.com/protocol/

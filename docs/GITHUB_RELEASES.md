# GitHub client release pipeline

Platforms: Android and native macOS. iOS has no app; Windows is paused. Existing
public releases remain unchanged; this change is not a new client version.

## Release contract

1. Update `versions.json` (Android or `native_macos`), increment version/build,
   supply user-facing notes, and set `release_status` to `candidate`. Android
   `app.json` and the encoded production versionCode must match. Merge the source
   through normal CI first. Do not reuse an existing tag, version or build.
   The Android builder manifest and APK filename retain the human build counter
   (1..99); the release manifest uses `major*1000000+minor*10000+patch*100+counter`
   as its build, matching the APK versionCode. Planning and bundling share this
   encoding and reject mismatched counters, debug variants and signer reports.
   Native macOS retains its builder's numeric string counter (CFBundleVersion)
   without Android encoding; both digit-string and integer counters are checked.
2. Dispatch **Client signed tag release**, `dry_run=true`, from main. Planning and
   locked dependency/quality checks run without signing secrets or publication.
3. Once receiver/site acceptance is complete and the repo variable
   `VEX_CLIENT_AUTOPUBLISH_ENABLED=true` is set, push the matching `android-vX.Y.Z`
   or `macos-vX.Y.Z` tag. A tag is the explicit publication action; an ordinary
   push to main never distributes a release.
4. Protected tag-only environments `client-release-signing` and
   `client-release-publish` separate signing and GitHub write permissions. Only
   the publish job receives content-write/OIDC/attestation permission. Actions
   are pinned by commit; dependencies install from the lockfile. No production
   admin token, VPN SSH access, DNS or tunnel mutation is available to this CI.
5. Builders verify production Android signer/package/ABI and the existing native
   macOS certificate/Sparkle contract. Uploaded assets are draft-only until every
   GitHub asset digest matches; official provenance attestations accompany them.
   Existing releases are never clobbered, deleted or retagged; platform releases
   do not compete for GitHub global Latest.
   Inspect the unpublished draft through the CLI's authenticated lookup and its
   exact repository/numeric release-ID API URL, not the published tag endpoint.
   Check draft/tag/source/ID identity again before verifying uploaded digests and
   making the release public; any mismatch leaves the draft unpublished.
6. GitHub sends its separately HMAC-signed `release.published` event to
   `https://vexguard.app/v1/webhooks/github/releases`. The API validates repository,
   tag, manifest, signer pin and immutable asset digests, and atomically imports
   stable metadata with a durable delivery receipt. Out-of-order and duplicate
   deliveries cannot downgrade or republish metadata. Public metadata AND actual
   website download redirect must match before the workflow reports acceptance.

## Activation gates

Deploy the matching server receiver/website changes with normal exact-source
acceptance and rollback, then provision a fresh release-only HMAC secret as
`VPN_GITHUB_RELEASE_WEBHOOK_SECRET` through private configuration. Create a GitHub
release-only webhook with the same secret, SSL verification on. Do not reuse a
payment/admin token or commit secret values. Verify signed ping and rejection of
invalid signatures, replay/ordering and current published releases unchanged.
Only then enable the repository flag. A green source check alone is not activation.

Signing secret names remain the existing Android upload keystore credentials and
macOS application P12/Sparkle key. Public certificate/Sparkle-key repo variables
are pins, not private credentials. Signing material is ephemeral and always cleaned.

## macOS compatibility limits

The existing distribution is **self-signed**, not Developer ID/notarized/Gatekeeper
ready. The workflow preserves this truth; paid Apple credentials are not invented.
New builds use `/v1/app/releases/macos/appcast.xml` backed by signed immutable
GitHub assets. Older installed clients still use the legacy static feed: a verified
legacy-feed bridge is required before claiming automatic delivery to those clients.

## Failure and rollback

A failed build/hash/signature never publishes. Failed draft upload remains private
for inspection. A GitHub-public release cannot be un-sent: if the website receipt
fails, inspect/redeliver the signed webhook, do not delete/recreate tags or force
metadata backward. Disable `VEX_CLIENT_AUTOPUBLISH_ENABLED` and deactivate the hook
as the release emergency stop. Use existing guarded admin rollback for a bad stable
client; the webhook deliberately cannot block builds or change compatibility/flags.
An old API binary ignores the additive receipt table; existing downloads remain.
An immutable tag whose build failed is retained for audit; merge the repair and
use a new version/build/tag instead of moving the failed tag or bypassing CI.

Standards: [GitHub security](https://docs.github.com/en/actions/how-tos/secure-your-work),
[environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations),
[Android signing](https://developer.android.com/studio/publish/app-signing),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Diagnostic network-cache acceptance

The diagnostics uploader caches a bounded network measurement by endpoint,
VPN state and the native peer handshake. A connect/disconnect or a fresh peer
must not reuse a result measured for the previous VPN context. An unchanged
context may reuse both healthy and failed measurements for 30 seconds; a
wall-clock rollback invalidates rather than extends that cache.

`node --test tests/diagnostics-network-context.test.cjs` exercises the complete
TypeScript module with isolated API, storage and native adapters. It checks
context transitions, same-context reuse, expiry, clock rollback, explicit
failures and the existing boolean wire contract. It does not operate a VPN,
authenticate a customer, or prove packet-level recovery on a phone.

The current server diagnostics model stores mandatory `dns_ok`/`https_ok`
booleans. Keep its legacy wire defaults while retaining the actual optional
measurement in `samples.network_probe`; sending an absent value alone would
be decoded as false by the existing backend. Tri-state measurement semantics
require a separate backward-compatible backend/storage/reader change.
The native status also needs a transport-generation signal to invalidate
cache across every Wi-Fi/mobile handoff; state/handshake coverage is not a
claim that this complete lifecycle matrix has passed.

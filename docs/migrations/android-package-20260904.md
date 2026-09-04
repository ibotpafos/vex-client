# Android restored-package migration

Decision: use com.vexguard.app and its recovered ORIGINAL signing key. Do not use the newly generated com.vexguard.vpn key for this package.

Candidate: 1.0.56/build1005658. Certificate SHA256 cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470. GitHub Actions run33816560036 verified certificate and private-key signing. Secrets remain in ibotpafos/vex-client; no private key exported.

Existing com.vexguard.app installs can be updated after signer/version checks. com.vexguard.client users require a separate install and login. Do not remove the old client or its data automatically. Only one VPN can be active.

Signing workflow verifies a fixed build-input SHA256, package and version before signing in CI, then publishes only a signed candidate artifact, not a public release. Preview OTA remains disabled. Public download/current signer metadata is unchanged until acceptance.

Release gates: fresh email and Google login, shared vexguard:// callback behavior with multiple installed VEX variants, Firebase/FCM, four endpoint handshakes/HTTPS/reconnect/network-change, compatibility with prior signed com.vexguard.app APK, clear migration instructions for com.vexguard.client. Candidate is not accepted merely because unit tests or signing pass.

The com.vexguard.vpn Firebase registration and protected key backups are unused recovery artifacts; do not delete or overwrite them silently.

## Verified candidate 2026-09-04

CI signing: https://github.com/ibotpafos/vex-client/actions/runs/33817173436 (success).
Signed APK SHA256: bd84f0c2cd6ca9b62d5177446d961b38f138b9cbfe41751645bb9a2206fd9a86.
Original signer SHA1: 4943331f7042edb7dfb91321d8863588a0d93ccc.
Both certificate fingerprints were saved and verified in Firebase for com.vexguard.app.
ADB install on Mi A1 succeeded; installed version1.0.56/code1005658 and onboarding UI verified. Existing client and Dev packages retained. Fresh authentication/VPN acceptance remains pending; this is not a production rollout.

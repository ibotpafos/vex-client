# Android restored-package migration

Decision: use com.vexguard.app and its recovered ORIGINAL signing key. Do not use the newly generated com.vexguard.vpn key for this package.

Candidate: 1.0.56/build1005658. Certificate SHA256 cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470. GitHub Actions run33816560036 verified certificate and private-key signing. Secrets remain in ibotpafos/vex-client; no private key exported.

Existing com.vexguard.app installs can be updated after signer/version checks. com.vexguard.client users require a separate install and login. Do not remove the old client or its data automatically. Only one VPN can be active.

Signing workflow verifies a fixed build-input SHA256, package and version before signing in CI, then publishes only a signed candidate artifact, not a public release. Preview OTA remains disabled. Public download/current signer metadata is unchanged until acceptance.

Release gates: fresh email and Google login, shared vexguard:// callback behavior with multiple installed VEX variants, Firebase/FCM, four endpoint handshakes/HTTPS/reconnect/network-change, compatibility with prior signed com.vexguard.app APK, clear migration instructions for com.vexguard.client. Candidate is not accepted merely because unit tests or signing pass.

The com.vexguard.vpn Firebase registration and protected key backups are unused recovery artifacts; do not delete or overwrite them silently.

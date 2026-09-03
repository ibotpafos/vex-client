# Android signing-loss migration candidate

User approved a new key and package after macOS/Keychain loss. Package `com.vexguard.vpn` is a NEW installation, not an update to `com.vexguard.client` or `com.vexguard.app`.

## Candidate

- Version1.0.56/build1005658. Previous package remains installed; do not uninstall or clear its data.
- Certificate SHA256: `46dae4f4218c7ae7b9e596fb7592308f29af211e762adbc4ba80ac89d0126c1d`.
- Local signing env: `/Users/ila/.config/vexguard/android-vpn-signing-20260904/.env.signing.local`; never commit its contents.
- Dedicated GitHub secrets: `ANDROID_VPN_RELEASE_KEYSTORE_BASE64`, `VEX_VPN_UPLOAD_STORE_PASSWORD`, `VEX_VPN_UPLOAD_KEY_PASSWORD`, `VEX_VPN_UPLOAD_KEY_ALIAS`, `ANDROID_VPN_BACKUP_PASSPHRASE`.
- Encrypted backup exists locally and on vex-de; decrypt round-trip and remote checksum verified. Password also held in Keychain service `vex/android-vpn-signing-backup-passphrase`.
- Preview candidate is release-signed but OTA disabled. Empty release checksum/signature metadata and is_required=false intentionally prevent presenting candidate metadata as a published release.

## User transition

Install the new APK alongside the old app. Sign in again using the same VEX account; account/subscription data stays on the server, Android sandbox credentials do not migrate. Grant VPN permission in the new app. Verify a working tunnel before suggesting removal of the old application. Only one VPN tunnel can be active at a time.

## Release gates still required

1. Verify new signer against the candidate registry and APK; physical side-by-side install.
2. Fresh email OTP and Google login with both packages installed. Current shared vexguard://auth/callback scheme can produce ambiguous routing: resolve/test before public release. Do not assume Google/Firebase registrations transfer between package IDs/certificates.
3. Register new package/certificate with Firebase/Google and verified App Links where needed; retain old associations during transition.
4. Four-node handshake/HTTPS/reconnect/network-change acceptance under new package.
5. Update backend signing registry/download metadata and web migration notice together. Do not force the old in-app updater to treat this as a same-package APK update; it correctly enforces package identity.
6. Publish a production-configured, signed candidate only after approval gates. Existing public APK remains unchanged until then.

Rollback before public release: restore source copies with artifact ROLLBACK.sh; leave existing app installed. Do not delete the new key or its recovery copies. A new-package uninstall is a separate user action and removes that package's local data.

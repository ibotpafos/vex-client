# macOS 0.1.90 (120)

Candidate: preserves the selected routing mode after provisioning errors and
timeouts, and includes the account/profile identity and bounded recovery fixes
accepted since 0.1.88. This release retains the packaged upstream AWG engine;
the shared Go engine and its new DIRECT policy are not enabled on macOS.

The reviewed Sparkle public key is in
`macos-native/sparkle-public-ed-key.txt`. It matches the immutable published
0.1.88/118 archive, its manifest and the existing CI public variable. Production
builds and preflight reject another key, including a stale local environment
file. CI continues using the existing signing secrets.

Some older manual installations, including the owner's 0.1.87, embed a different
key. They cannot automatically accept the current ZIP signature. Use a one-time
manual installation from [the official download](https://vexguard.app/downloads/macos/latest)
when VPN is disconnected; subsequent releases use the retained stable key.
Do not disable signature verification or replace a running application/helper
to perform this migration.

Sparkle's [key rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys)
require a Developer ID signed disk image to change the EdDSA key when verification
before extraction is enabled. The existing self-signed ZIP distribution does
not meet that migration contract. Developer ID, notarization and first-launch
Gatekeeper acceptance are not claimed by this candidate.

Publication and installation acceptance remain pending until the exact signed
candidate and public update/download receipts are verified. The active host VPN
must remain untouched during release preparation.

# macOS 0.1.90 (120)

Published on 20 October 2026 at 13:44 Moscow time: preserves the selected routing mode after provisioning errors and
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

The immutable [release](https://github.com/ibotpafos/vex-client/releases/tag/macos-v0.1.90)
was published from `439cec873fd40b234d70976c682379305d6280a8` by protected
workflow run `39409362771`. Release planning, locked quality checks, native
signing, immutable publication and the website receipt gate passed. The API
and both Sparkle feed paths select build 120.

The separate source-bound candidate `39406949962` passed SHA-256, Ed25519,
bundle key/version, universal architecture and Russian release-note checks in
memory. Package bytes were not written to the space-constrained D volume.
The candidate CI verified nested code signatures; this is not a claim of a
local physical installation or fresh tunnel test. The owner's installed 0.1.87
and active VPN were preserved. Physical install/upgrade/rollback and notification
permission acceptance still need an isolated Mac.

Public acceptance at 13:48 Moscow time verified all six GitHub asset digests,
the immutable tag/source binding, Ed25519 on both legacy and API appcasts,
the native update-check response from 0.1.88 and the website download redirect.
The published ZIP is 15,814,132 bytes with SHA-256
`a71f0177f4fd6aadaf4ced2eaa9dabb29f51e76ecb1f2af88b53e08915101bd9`.
Its actual bundle retains the stable key and verification before extraction,
and uses the API appcast URL. Public package bytes were checked in memory;
the installed app and active VPN were unchanged.

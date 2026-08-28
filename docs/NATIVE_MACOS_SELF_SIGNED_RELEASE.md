# Native macOS release channels

VEX has two intentionally separate macOS distribution channels. A manifest
must satisfy exactly one channel contract; changing a filename or boolean does
not promote a self-signed build to production.

| Property | Self-signed channel | Developer ID production channel |
| --- | --- | --- |
| App signature | Stable VEX self-signed certificate, SHA-256 pinned | Developer ID Application |
| PKG signature | Unsigned outer PKG; SHA-256 published, payload certificate-pinned | Developer ID Installer |
| Apple notarization | No | Required and stapled |
| Gatekeeper-ready | No | Required |
| User approval | Privacy & Security > Open Anyway | Normal Installer flow |
| Manifest channel | `self-signed` | Developer ID production fields |

The self-signed channel provides payload tamper detection and continuity between
VEX builds. The outer PKG is intentionally unsigned because PackageKit rejects
an untrusted self-signed installer certificate with `PKInstallErrorDomain 102`
and `CSSMERR_TP_NOT_TRUSTED` before postinstall. It does not let macOS
authenticate VEX as an Apple-identified developer and is never described as
notarized or Gatekeeper-ready.

## Create the stable release identities once

Run the following on the controlled release Mac. Keep the output directory,
keychain password, private PEM keys, and PKCS#12 files private and outside Git.
Do not regenerate identities for each release because the certificate
fingerprints are the channel's pinned identity.

Resolve Swift packages first so Sparkle's official `generate_keys` tool is
available. The identity script creates or reuses the Keychain account
`vex-vpn-self-signed`, exports its private Ed25519 seed into the protected
release directory, and writes both Sparkle variables to `release.env`.

```bash
cd macos-native && swift package resolve && cd ..
VEX_SELF_SIGNED_KEYCHAIN_PASSWORD='KEYCHAIN_PASSWORD' \
VEX_SELF_SIGNED_P12_PASSWORD='P12_PASSWORD' \
./scripts/create_native_macos_self_signed_identities.sh /secure/vex-macos-self-signed-v1
```

## Build and verify a self-signed release

```bash
source /secure/vex-macos-self-signed-v1/release.env
security unlock-keychain -p 'KEYCHAIN_PASSWORD' "$VEX_CODESIGN_KEYCHAIN"
VEX_NATIVE_VERSION=0.1.87 \
VEX_NATIVE_BUILD=117 \
./scripts/build_native_macos_self_signed_release.sh
```

The workflow builds universal app/helper binaries, signs the app and nested
code, builds the real unsigned outer PKG with its postinstall helper flow, pins
the application certificate SHA-256 fingerprint, and creates a separate
manifest and deploy bundle. Preflight confirms both architectures, strict
payload code signatures, the unsigned PackageKit format, the certificate
fingerprint, and the helper installer contract.
The self-signed app keeps Sparkle and automatic Ed25519-verified updates. A
non-Apple self-signed certificate has no TeamIdentifier, so strict hardened
runtime library validation rejects a bundled framework even when it is signed
with the same certificate. The self-signed app therefore keeps hardened runtime
but uses the narrow app entitlement
`com.apple.security.cs.disable-library-validation`; Sparkle and its nested code
are still signed and verified during preflight. This exception changes only the
VEX process runtime policy and does not change Gatekeeper, SIP, certificate
trust, or any global macOS setting. Developer ID production does not use this
self-signed entitlement.

Never publish private keys, PKCS#12 files, or keychain passwords. The PEM
application certificate and manifest fingerprint are public verification
material. Do not import the certificate into an end user's trust store.
Keep the same Sparkle Ed25519 private key for every later self-signed release.
Builds that embed a different `SUPublicEDKey` cannot accept this channel's
archives and require one manual install to join it; after that, normal Sparkle
updates use the stable key and appcast.

## User installation flow

1. Download the self-signed PKG from the VEX macOS page and open it once.
2. If macOS blocks it, leave Gatekeeper enabled. Open **System Settings >
   Privacy & Security**.
3. In **Security**, click **Open Anyway**. Apple exposes this button for about
   one hour after the blocked open attempt. This approval is for the exact
   downloaded PKG; it does not add a signing certificate to system trust.
4. Authenticate, open the PKG again, and approve Installer's administrator
   prompt. Postinstall copies a root-owned app snapshot, verifies the pinned
   app certificate, installs only the signed helper resources, launches the
   helper, and requires a valid `status` response before succeeding.
5. Launch VEX and connect.

Do not use `spctl --master-disable`, remove quarantine attributes, import the
self-signed certificate, alter system trust settings, or disable other macOS
protections. If **Open Anyway** is not shown, open the PKG once more and return
to Privacy & Security.

## Future Developer ID release

`scripts/build_native_macos_public_release.sh` remains the only production
path. It still requires Developer ID Application and Developer ID Installer
identities, notarizes and staples both app and PKG, and requires Gatekeeper
assessment before creating a production-ready manifest.

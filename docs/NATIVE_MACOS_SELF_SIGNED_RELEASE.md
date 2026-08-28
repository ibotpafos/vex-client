# Native macOS release channels

VEX has two intentionally separate macOS distribution channels. A manifest
must satisfy exactly one channel contract; changing a filename or boolean does
not promote a self-signed build to production.

| Property | Self-signed channel | Developer ID production channel |
| --- | --- | --- |
| App signature | Stable VEX self-signed certificate, SHA-256 pinned | Developer ID Application |
| PKG signature | Stable VEX self-signed installer certificate, SHA-256 pinned | Developer ID Installer |
| Apple notarization | No | Required and stapled |
| Gatekeeper-ready | No | Required |
| User approval | Privacy & Security > Open Anyway | Normal Installer flow |
| Manifest channel | `self-signed` | Developer ID production fields |

The self-signed channel provides tamper detection and continuity between VEX
builds. It does not let macOS authenticate VEX as an Apple-identified developer
and is never described as notarized or Gatekeeper-ready.

## Create the stable release identities once

Run the following on the controlled release Mac. Keep the output directory,
keychain password, private PEM keys, and PKCS#12 files private and outside Git.
Do not regenerate identities for each release because the certificate
fingerprints are the channel's pinned identity.

```bash
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
code, builds the real PKG with its postinstall helper flow, signs the PKG,
pins both certificate SHA-256 fingerprints, and creates a separate manifest and
deploy bundle. Preflight confirms both architectures, strict code signatures,
PKG signature, certificate fingerprints, and the helper installer contract.
The self-signed bundle intentionally has no Sparkle appcast; automatic updates
remain reserved for the Developer ID/notarized production channel.

Never publish private keys, PKCS#12 files, or keychain passwords. The PEM
certificate files and manifest fingerprints are public verification material.

## User installation flow

1. Download the self-signed PKG from the VEX macOS page and open it once.
2. If macOS blocks it, leave Gatekeeper enabled. Open **System Settings >
   Privacy & Security**.
3. In **Security**, click **Open Anyway**. Apple exposes this button for about
   one hour after the blocked open attempt.
4. Authenticate, open the PKG again, and approve Installer's administrator
   prompt. Postinstall copies a root-owned app snapshot, verifies the pinned
   app certificate, installs only the signed helper resources, launches the
   helper, and requires a valid `status` response before succeeding.
5. Launch VEX and connect.

Do not use `spctl --master-disable`, remove quarantine attributes, alter system
trust settings, or disable other macOS protections. If **Open Anyway** is not
shown, open the PKG once more and return to Privacy & Security.

## Future Developer ID release

`scripts/build_native_macos_public_release.sh` remains the only production
path. It still requires Developer ID Application and Developer ID Installer
identities, notarizes and staples both app and PKG, and requires Gatekeeper
assessment before creating a production-ready manifest.

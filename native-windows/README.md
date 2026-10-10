# VEX Native for Windows

This directory contains the standalone WinUI client for Windows.
Development reopened on 2026-10-10 to deliver native macOS feature parity.
The earlier 2026-09-25 pause is superseded for source work and unsigned CI.
Promotion requires the full parity and real-device acceptance matrix below;
existing published Windows artifacts remain available until those gates pass.

## Architecture

- `Vex.Windows.App`: WinUI 3 / Windows App SDK 2.2 UI, single user context.
- `Vex.Windows.Client`: platform-neutral control-plane client, session
  coordinator, and X25519/WireGuard device identity.
- `Vex.Windows.Core`: immutable VPN state, validation, signed-profile
  authorization, and the versioned UI-to-service contract. The client and core
  projects are tested on macOS and Windows.
- `Vex.Windows.Service`: privileged LocalSystem Windows Service exposed through
  the authenticated `VexVpn.Service.v2` named pipe. It owns the
  AmneziaWG process, Wintun adapter, routes, DNS, anti-leak policy, recovery,
  and tunnel diagnostics. The UI must never perform privileged tunnel changes.
- Secure session storage: per-user DPAPI (`CurrentUser`) protects persisted
  access tokens and device identity keys. The service IPC credential uses
  machine-scoped DPAPI and install-time ACLs. The native tunnel configuration
  required by AmneziaWG is restricted to LocalSystem.
- Distribution: signed x64/arm64 MSIX packages plus `.appinstaller`; native update metadata
  remains unchanged until native Windows promotion.

## macOS parity contract

| Surface | Required Windows behavior | Acceptance evidence |
| --- | --- | --- |
| Authentication | Browser/Google PKCE/deep link, email OTP, refresh, logout, Windows Hello unlock on Windows 11 | Cold start, expired token, duplicate callback, offline recovery |
| Home | Status restoration, connect/disconnect, autopilot, manual location, latency, server switching | Real tunnel traffic, kill/restart, sleep/wake, network handover |
| VPN safety | Wintun/AmneziaWG lifecycle, DNS and route cleanup, anti-leak, control-plane bypass | IPv4/IPv6/DNS leak checks and protected-host access |
| Account | User, devices, usage, entitlement and the shared website billing dashboard | Production read-only API contract fixtures and browser return |
| Support | Tickets, real-time chat, optimistic send, diagnostics attachment | Reconnect, duplicate event, queued diagnostic retry |
| Settings | Startup, biometric lock, diagnostics, update center, quit behavior | Reboot, service recovery, required update |
| Shell | Single instance, protocol activation, system tray, show/hide, connect/disconnect, quit | Repeated launch and tray-only operation |
| Updates | Signed MSIX/App Installer, staged rollout, required update, rollback | Upgrade and downgrade drill |

## Current parity implementation and remaining acceptance

The Windows service admits the same AWG3.1 header protection, padding, timing
and boolean configuration fields as macOS. A connection requires a recent
handshake from the configured peer through AmneziaWG UAPI, verified routes,
DNS and anti-leak policy. Physical-interface changes reconcile owned bypass
routes; service shutdown restores the recorded firewall and route state.

The vendor executable must implement `/installtunnelservice` and
`/uninstalltunnelservice`. Use the CLI-capable
`amnezia-vpn/amneziawg-windows-client` 3.1.0 runtime (AWG Go 3.1.20260814),
qualified separately on each architecture. The distinct
`amnezia-vpn/amneziawg-windows` project produces an embeddable `tunnel.dll`
and does not satisfy this executable contract. PE hashes and architecture
checks establish the selected artifact's identity; the Windows acceptance
drill must also establish AWG3.1 protocol compatibility.

Monitoring belongs to the application lifetime, so navigation and tray-only
operation retain status, recovery and diagnostics retries. Recovery preserves
manual location pins, tries a fresh signed profile for the same exit, and only
allows an alternate exit in automatic mode. Subscription expiry and session
revocation prevent cached-profile reconnects. Google/email authentication,
website billing, support message reconciliation and incident configuration
follow the current macOS product flows.

The server catalog groups nodes by country, searches localized country/city
labels, and retains favorites and all/fastest/favorites/available filters.
An explicit quit waits for confirmed tunnel cleanup and seals pending UI
operations against a late reconnect; a failed cleanup keeps the app available
for retry.

Resilience policies are cached in per-user DPAPI storage and route health uses
expiry, quarantine and sticky selection. They are advisory: the service still
requires a signed profile for the exact endpoint. The current profile API
cannot issue a signed grant for a requested relay/path candidate, and the
resilience response does not provide a release-pinned trust anchor. Therefore
switching to a different relay endpoint is a remaining backend contract gap;
Windows must not substitute an unsigned endpoint into an admitted profile.

Portable behavioral tests and cross-compilation establish source correctness.
The scoped Windows CI compiles and publishes both x64 and arm64 WinUI/service
payloads. Neither proves real-device VPN acceptance: signed installation,
traffic/leak checks, sleep/wake, network handover, and upgrade/rollback/uninstall
must still be exercised on Windows before production promotion.

## Delivery phases

1. **Foundation**: native shell, immutable state reducer, versioned IPC contract,
   Windows CI, MSIX identity, signed artifact skeleton.
2. **Tunnel service**: authenticated named pipe, Windows Service installer,
   AmneziaWG/Wintun lifecycle, status restoration, anti-leak, diagnostics.
3. **Auth and control plane**: PKCE/OTP, DPAPI-protected identity, profile/key
   lifecycle, locations, entitlement, connect reporting.
4. **Full product parity**: account/billing, support socket, settings, tray,
   Windows Hello, update center.
5. **Release hardening**: x64/arm64 packages, Authenticode, install/upgrade
   migration, crash and lifecycle matrix, canary rollout.
6. **Cutover**: promote native metadata only after all parity gates pass; retain
   a previous signed native package as an explicit rollback release.

## Local checks

The platform-neutral client, PowerShell release checks and cross-compiled
service can be checked from Linux or macOS with .NET 10, Node, Python 3 and
PowerShell 7 installed:

```bash
bash scripts/native_windows_preflight.sh
```

Individual checks:

```bash
dotnet run --project native-windows/tests/Vex.Windows.Core.Tests/Vex.Windows.Core.Tests.csproj
dotnet build native-windows/src/Vex.Windows.Service/Vex.Windows.Service.csproj -c Release -r win-x64 -p:EnableWindowsTargeting=true
```

The WinUI project requires a Windows host with the Windows SDK:

```powershell
dotnet publish native-windows/src/Vex.Windows.App/Vex.Windows.App.csproj -c Release -r win-x64 -p:Platform=x64
dotnet publish native-windows/src/Vex.Windows.App/Vex.Windows.App.csproj -c Release -r win-arm64 -p:Platform=arm64
```

Clean Windows development hosts must also install the current Microsoft Visual
C++ 2015-2022 Redistributable for their architecture before running the core
tests. `NSec.Cryptography` uses the native libsodium runtime. Release MSIX
packages declare `Microsoft.VCLibs.140.00.UWPDesktop` so Windows can resolve the
same prerequisite during packaged installation.

Windows Hello desktop verification uses the window-bound interop API available
on Windows 11 (build 22000+). Windows 10 keeps DPAPI protection but does not
offer the additional Hello session gate.

The release packager signs the app and service PE files before signing the
MSIX. It emits `package-metadata.json` (schema
`vex.windows-package-output.v2`) with pins for the signing certificate, app,
service, `amneziawg.exe`, `wintun.dll`, and the profile-signing keyring. It also
emits a bootstrap plus install/uninstall helpers next to the MSIX. No IPC
credential or other secret is present in those artifacts.

The keyring is release-generated and contains public keys only:

```json
{
  "schema": "vex.profile-signing-keyring.v1",
  "keys": [
    {
      "key_id": "native-profile-p256-v1",
      "algorithm": "ECDSA_P256_SHA256_DER",
      "subject_public_key_info_base64": "<P-256 SPKI base64>"
    }
  ]
}
```

The matching PKCS#8 or SEC1 private key is supplied only to the API through
`VPN_NATIVE_PROFILE_P256_PRIVATE_KEY`; it must never be packaged with either
Windows binary.

The MSIX contains the signed service binary and runtime assets, but deliberately
does not declare a packaged service or LocalSystem service capability. There is
one service ownership model: the elevated bootstrap provisions and owns the
manual `sc.exe` service. A raw MSIX or `.appinstaller` registration installs or
updates only the application payload; it does not provision, repair, update, or
remove the VPN service.

Every initial install, repair, update, rollback, and uninstall must enter
through the emitted bootstrap from the versioned artifact directory:

```powershell
# Install the signed MSIX, provision ProgramData, and verify the running service.
.\bootstrap-native-windows.ps1 -Action Install

# Repeat all hash/state/service checks without changing installation state.
.\bootstrap-native-windows.ps1 -Action Verify

# Re-provision a damaged ProgramData state from the signed installed payload.
.\bootstrap-native-windows.ps1 -Action Repair

# Remove the tunnel service, ProgramData authorization state, and MSIX.
.\bootstrap-native-windows.ps1 -Action Uninstall

# Replace the current release with a retained previous artifact.
.\bootstrap-native-windows.ps1 -Action Rollback `
  -RollbackPackagePath C:\VEX\previous\VEX.Native.stable.x64.1.2.3.4.msix `
  -RollbackMetadataPath C:\VEX\previous\package-metadata.json
```

Install/repair creates `%ProgramData%\VEX\VPN` with protected inheritance and
explicit access for LocalSystem, Administrators, and the owning user SID. A
fresh 256-bit IPC credential is generated with the Windows CSPRNG and protected
using machine-scoped DPAPI. The bootstrap verifies all release pins and waits
for `VEX VPN Service` to reach `Running` before reporting success.

The signed public `update.json` release pairs the exact MSIX, bootstrap,
install/uninstall helpers, and `package-metadata.json` URIs, SHA-256 hashes, and
sizes. Publishing also emits signed `bootstrap-entry.json` plus
`bootstrap-entry.json.sig`. Update consumers must stage the MSIX, metadata, and
all three PowerShell scripts into one directory, verify that signed entry, and
launch `bootstrap-native-windows.ps1` elevated. Direct launch of the MSIX or
AppInstaller is not a complete VEX VPN installation/update path.

The native app therefore owns the Sparkle-equivalent lifecycle. Automatic
checks are enabled by default, run shortly after startup and every six hours,
back off for fifteen minutes after transient failures, and can be disabled in
Settings. A verified available release is surfaced in the tray and Update
Center; installation always stages every signed artifact and enters through
the elevated bootstrap so the app and privileged service advance atomically.
The `.appinstaller` intentionally has no package-only background update task.

Packaging still requires the existing x64/arm64 release environment variables,
Windows SDK (`makeappx`, `signtool`), runtime inputs, and a PFX
provided through the CI environment. The temporary PFX is deleted after each
signing phase. The profile and update private keys remain server/CI-only.
Architecture-specific runtime paths use
`VEX_WINDOWS_SERVICE_AMNEZIAWG_PATH_X64`/`_ARM64` and
`VEX_WINDOWS_SERVICE_WINTUN_PATH_X64`/`_ARM64`. The legacy unsuffixed paths remain
a fallback, but all executables and Wintun DLLs must match the package PE
architecture. A single x64 Wintun DLL cannot be reused in an arm64 release.
The packager removes previous staging contents and stops on any publish error.

For clean hosted release runners, set
`VEX_WINDOWS_SERVICE_AMNEZIAWG_URI_X64`/`_ARM64` and
`VEX_WINDOWS_SERVICE_WINTUN_URI_X64`/`_ARM64`, with the corresponding
`VEX_WINDOWS_SERVICE_AMNEZIAWG_SHA256_X64`/`_ARM64` and
`VEX_WINDOWS_SERVICE_WINTUN_SHA256_X64`/`_ARM64` pins. The runtime staging helper
downloads HTTPS assets, verifies their hashes and PE architectures, and sets
the architecture-specific paths before packaging.

PE, MSIX and bootstrap signatures are timestamped. Override the default
timestamp service with `VEX_WINDOWS_SIGN_TIMESTAMP_URI` when needed; signing
or signature verification failure stops packaging.

Each publish must also set a strictly increasing
`VEX_WINDOWS_MANIFEST_REVISION`. Set
`VEX_WINDOWS_REQUIRED_VERSION_FLOOR` when raising the persisted minimum
security floor; otherwise the publisher uses
`VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION` or the release version. A floor increase
prevents later downgrade below that version, so select it before signing.

The separate Native Windows CI workflow runs portable tests plus Windows x64
and arm64 self-contained publishes for scoped PR/main changes. It verifies
published native executable architectures and required application assets.
Routine jobs do not access signing secrets. Manual validation needs no release
inputs; signed release preparation requires `package_release=true`, the main
branch, release version/revision/notes, and the configured release inputs.
Signed output is retained for review; the workflow does not promote it to a
public update origin.

Cross-platform packaging checks:

```bash
node native-windows/scripts/validate-packaging-static.mjs
```

PowerShell 7 provides the actual AST parser and release validation tests on
Linux, macOS and Windows:

```powershell
.\native-windows\scripts\validate-powershell-parse.ps1
.\native-windows\tests\ReleaseValidation.Tests.ps1
```

Before promotion, both x64 and arm64 still require a clean real-Windows
install/upgrade/rollback/uninstall drill, Authenticode/MSIX trust verification,
service recovery after reboot, and tunnel/DNS/route cleanup tests.
Portable checks and hosted compilation do not establish that real-device
acceptance has passed.

## Decision record

WinUI 3 was chosen over WPF and Qt because it is
Microsoft's current native desktop stack, maps closely to the existing SwiftUI
architecture, supports modern Windows lifecycle APIs, and removes WebView from
the critical UI path. A separate service is mandatory because UI crashes,
updates, and user logoff must not leave routes, DNS, or the tunnel in an
unknown state.

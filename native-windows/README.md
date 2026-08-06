# VEX Native for Windows

This directory contains the standalone WinUI client for Windows.
The native release is the supported Windows desktop lane.
client passes the full parity and real-device acceptance matrix.

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
- Secure session storage: per-user DPAPI (`CurrentUser`); no access token or
  tunnel private key is stored in plain text. The service IPC credential uses
  machine-scoped DPAPI and install-time ACLs.
- Distribution: signed MSIX bundle plus `.appinstaller`; native update metadata
  remains unchanged until native Windows promotion.

## macOS parity contract

| Surface | Required Windows behavior | Acceptance evidence |
| --- | --- | --- |
| Authentication | Browser PKCE/deep link, email OTP, refresh, logout, Windows Hello unlock on Windows 11 | Cold start, expired token, duplicate callback, offline recovery |
| Home | Status restoration, connect/disconnect, autopilot, manual location, latency, server switching | Real tunnel traffic, kill/restart, sleep/wake, network handover |
| VPN safety | Wintun/AmneziaWG lifecycle, DNS and route cleanup, anti-leak, control-plane bypass | IPv4/IPv6/DNS leak checks and protected-host access |
| Account | User, devices, usage, entitlement, plans, checkout, cancellation, portal, payment history | Production read-only API contract fixtures and browser return |
| Support | Tickets, real-time chat, optimistic send, diagnostics attachment | Reconnect, duplicate event, queued diagnostic retry |
| Settings | Startup, biometric lock, diagnostics, update center, quit behavior | Reboot, service recovery, required update |
| Shell | Single instance, protocol activation, system tray, show/hide, connect/disconnect, quit | Repeated launch and tray-only operation |
| Updates | Signed MSIX/App Installer, staged rollout, required update, rollback | Upgrade and downgrade drill |

## Delivery phases

1. **Foundation**: native shell, immutable state reducer, versioned IPC contract,
   Windows CI, MSIX identity, signed artifact skeleton.
2. **Tunnel service**: authenticated named pipe, Windows Service installer,
   AmneziaWG/Wintun lifecycle, status restoration, anti-leak, diagnostics.
3. **Auth and control plane**: PKCE/OTP, Credential Locker, profile/key
   lifecycle, locations, entitlement, connect reporting.
4. **Full product parity**: account/billing, support socket, settings, tray,
   Windows Hello, update center.
5. **Release hardening**: x64/arm64 packages, Authenticode, install/upgrade
   migration, crash and lifecycle matrix, canary rollout.
6. **Cutover**: promote native metadata only after all parity gates pass; retain
   a previous signed native package as an explicit rollback release.

## Local checks

The platform-neutral foundation can be checked from macOS:

```bash
dotnet run --project native-windows/tests/Vex.Windows.Core.Tests/Vex.Windows.Core.Tests.csproj
dotnet build native-windows/src/Vex.Windows.Service/Vex.Windows.Service.csproj -c Release -r win-x64 -p:EnableWindowsTargeting=true
```

The WinUI project requires a Windows host with the Windows SDK:

```powershell
dotnet build native-windows/src/Vex.Windows.App/Vex.Windows.App.csproj -c Release -r win-x64
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
Windows SDK (`makeappx`, `makepri`, `signtool`), runtime inputs, and a PFX
provided through the CI environment. The temporary PFX is deleted after each
signing phase. The profile and update private keys remain server/CI-only.
Each publish must also set a strictly increasing
`VEX_WINDOWS_MANIFEST_REVISION`. Set
`VEX_WINDOWS_REQUIRED_VERSION_FLOOR` when raising the persisted minimum
security floor; otherwise the publisher uses
`VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION` or `0.0.0.0` for the initial release.

Cross-platform packaging checks:

```bash
node native-windows/scripts/validate-packaging-static.mjs
```

On Windows, additionally run the actual PowerShell AST parser:

```powershell
.\native-windows\scripts\validate-powershell-parse.ps1
```

Before promotion, both x64 and arm64 still require a clean real-Windows
install/upgrade/rollback/uninstall drill, Authenticode/MSIX trust verification,
service recovery after reboot, and tunnel/DNS/route cleanup tests.

## Decision record

WinUI 3 was chosen over WPF and Qt because it is
Microsoft's current native desktop stack, maps closely to the existing SwiftUI
architecture, supports modern Windows lifecycle APIs, and removes WebView from
the critical UI path. A separate service is mandatory because UI crashes,
updates, and user logoff must not leave routes, DNS, or the tunnel in an
unknown state.

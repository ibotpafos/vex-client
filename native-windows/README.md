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
- `Vex.Windows.Setup`: native Windows installer with an embedded immutable release
  description, verified adjacent bundle and original-user service bootstrap.
- Distribution: signed x64/arm64 installer bundles containing Setup, MSIX,
  Microsoft VCLibs and service helpers; native update metadata remains unchanged
  until native Windows promotion.

## macOS parity contract

| Surface | Required Windows behavior | Acceptance evidence |
| --- | --- | --- |
| Authentication | Browser/Google PKCE/deep link, email OTP, refresh, logout, Windows Hello unlock on Windows 11 | Cold start, expired token, duplicate callback, offline recovery |
| Home | Status restoration, connect/disconnect, autopilot, manual location, latency, server switching | Real tunnel traffic, kill/restart, sleep/wake, network handover |
| VPN safety | Wintun/AmneziaWG lifecycle, DNS and route cleanup, anti-leak, control-plane bypass | IPv4/IPv6/DNS leak checks and protected-host access |
| Account | User, devices, usage, entitlement and the shared website billing dashboard | Production read-only API contract fixtures and browser return |
| Support | Open the shared VEX support website from Settings, matching macOS | Website action available with or without a signed-in session |
| Settings | Startup, biometric lock, diagnostics, update center, quit behavior | Reboot, service recovery, required update |
| Shell | Single instance, protocol activation, system tray, show/hide, connect/disconnect, quit | Repeated launch and tray-only operation |
| Updates | Signed MSIX/App Installer, staged rollout, required update, rollback | Upgrade and downgrade drill |

## Current parity implementation and remaining acceptance

The Windows service admits the same AWG3.1 header protection, padding, timing
and boolean configuration fields as macOS. A connection requires a recent
handshake from the configured peer through AmneziaWG UAPI, verified routes,
DNS and anti-leak policy. Physical-interface changes reconcile owned bypass
routes; service shutdown restores the recorded firewall and route state.
DNS lookup has a four-second budget. Recovery first reconciles the last numeric
address bound to the exact signed endpoint, peer key and authorization lease;
status reads use known addresses without DNS. A cold service or a newly observed
authenticated peer reconciles that numeric route before reporting health.
Bypass verification checks both the effective interface and next-hop gateway,
and preserves routes owned by other applications. The anti-leak endpoint rule
permits only UDP to the signed port; a separate control-plane rule permits HTTPS.
Control-plane DNS metadata survives restart only for the configured host set,
the admitted endpoint and peer, and its unexpired lease. Numeric priming restores
those escapes before DNS can depend on a damaged tunnel. Removing a bypass
requires a durable creation receipt and matching route metric and protocol.
Unconfirmed or legacy routes with ambiguous ownership retain their journal and
report incomplete cleanup instead of deleting a matching foreign route.
Disconnect cancels an in-flight repair and fences its service restart.
The signed authorization deadline also cancels connection and repair waits;
the runtime rechecks expiry before starting the service and committing a
connection. A renewed lease has its own deadline and cannot be canceled by an
older lease callback.

The vendor executable must implement `/tunnelservice` and
`/uninstalltunnelservice`. VEX registers its exact LocalSystem tunnel service
with demand start and an unrestricted service SID, then starts it only after
network protection is ready. Upgrade stops and unregisters an owned older vendor
service before replacing the package. Retained registrations cannot restart
an unauthorized tunnel at boot. Use the CLI-capable
`amnezia-vpn/amneziawg-windows-client` 3.1.0 runtime (AWG Go 3.1.20260814),
qualified separately on each architecture. The distinct
`amnezia-vpn/amneziawg-windows` project produces an embeddable `tunnel.dll`
and does not satisfy this executable contract. PE hashes and architecture
checks establish the selected artifact's identity; the Windows acceptance
drill must also establish AWG3.1 protocol compatibility.

Monitoring belongs to the application lifetime, so navigation and tray-only
operation retain status, recovery and diagnostics retries. Recovery preserves
manual location pins, exhausts qualified ingress paths for the same exit,
refreshes its signed profile, and allows an alternate exit in automatic mode. Subscription expiry and session
revocation prevent cached-profile reconnects. Google/email authentication,
website billing, website support and incident configuration
follow the current macOS product flows.

Password, email and browser login save the authenticated account before VPN
provisioning. An unpaid account, a full device quota or unavailable exits can
still open Account, billing and website support. The first Connect checks
entitlement and registers a device; device identity and cached grants cannot
cross accounts. Windows Hello changes are committed only after confirmation
and a durable protected preference write.

Home uses the macOS dark/cyan palette, six animated focus rings, traffic
sparklines, country cards and bottom navigation. Account and Settings retain
the same centered desktop proportions; narrow windows adapt the cards and
navigation. System reduced-motion settings disable the focus animation.
An in-flight connection can be cancelled; its independent disconnect command
waits for service cleanup rather than merely cancelling the UI pipe read.
Server selection retains its keyboard highlight through catalog refreshes and
rejects changes during connection or cleanup. The health indicator reflects
the current catalog, including partial outages and maintenance. Settings keep
local preferences available during status loading and cancel page reads when
navigation changes. The desktop minimum size adapts to DPI and the work area.

An expired realtime access token or server session-invalid event triggers
bounded refresh attempts. Network failures preserve the session and working
tunnel; an authoritative refresh rejection signs out and disconnects. Events from an earlier token
cannot invalidate a newer login. Account loading keeps authoritative
entitlement visible when optional plans, payments, devices or usage fail,
with separate cached/unavailable indicators for each affected section.
Silent realtime headers or body reads have a 90-second liveness deadline;
reconnection retains the last event cursor and does not reject credentials.
Required updates stay blocked after installer launch and an offline restart
until the running version satisfies the verified requirement.
Unreadable protected update records keep Connect blocked while Account and
Settings remain available for recovery. Downloading the complete verified
installer bundle has a fifteen-minute deadline; cancellation removes partial
files and allows another attempt.

Periodic subscription checks bind their result to the current account and
connection intent. A delayed response cannot disconnect a newer login or
server selection. Windows Hello locking and temporary network failures preserve
an admitted tunnel; a current authoritative rejection requests confirmed cleanup.

Disconnected clients warm their selected profile without blocking Connect.
The warm cache requires the release-pinned P256 keyring, exact signed user,
device, location and routing scope, and matching HTTPS device-key metadata.
Warm-up cannot change the active profile or connection preference; login,
key, routing and connection changes invalidate pending work. Older servers
without device-key metadata use the ordinary foreground profile flow.
An exact warmed grant and bounded cached paid entitlement also support cold
automatic connection during transient catalog failures. A fresh negative
entitlement supersedes an older paid cache; authentication failures and grants
for another mode, identity or expired lease never enable this fallback.

The server catalog groups nodes by country, searches localized country/city
labels, and retains favorites and all/fastest/favorites/available filters.
An explicit quit waits for confirmed tunnel cleanup and seals pending UI
operations against a late reconnect; a failed cleanup keeps the app available
for retry.
Tray connection attempts without an unlocked session open Home, where the
existing sign-in or Windows Hello unlock controls are available.

Resilience policies are cached in per-user DPAPI storage and route health uses
expiry, quarantine and sticky selection. A changed endpoint requires the additive
`GET /v1/vpn/profile?...&candidate_id=...` backend contract: the server resolves
the identifier against its qualified topology for the current user, device and
assigned exit, then issues the existing P256 profile with an exact endpoint and
a lease of at most ten minutes. The service uses its release-pinned keyring;
policy keys supplied by the response do not authorize configuration changes.
The companion backend implementation is [VPN #741](https://github.com/ibotpafos/VPN/pull/741);
it is merged and must be deployed before new path grants can be issued. Servers
without this contract retain direct-profile recovery.

After a successful connection, Windows prefetches at most three independently
signed current-policy grants within an eight-second budget. Its DPAPI-protected
pool binds user, device, exit, routing, bypass and local key identity. Offline
failover can use those grants until the earlier signed or policy expiry;
uncached paths and expired grants require the API. Partial prefetch preserves
valid existing leases. Recovery permits at most three same-exit path attempts,
one fresh same-exit profile and one automatic alternate exit: five service
attempts total, or four when recovery already begins with a fresh profile.

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
4. **Full product parity**: account/billing, website support, settings, tray,
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
same prerequisite during packaged installation. Release bundles include the
architecture-matched, Microsoft-signed framework; bootstrap passes it through
`Add-AppxPackage -DependencyPath` when needed and preserves a newer installed
framework belonging to Microsoft.

Windows Hello desktop verification uses the window-bound interop API available
on Windows 11 (build 22000+). Windows 10 keeps DPAPI protection but does not
offer the additional Hello session gate.

The release packager signs the app and service PE files before signing the
MSIX. It emits `package-metadata.json` (schema
`vex.windows-package-output.v2`) with pins for the signing certificate, app,
service, `amneziawg.exe`, `wintun.dll`, and the profile-signing keyring. It also
emits a bootstrap plus install/uninstall helpers and the Microsoft framework
next to the MSIX. After metadata is final, it embeds those exact bytes into
`VEX.Setup.x64.exe` or `VEX.Setup.arm64.exe` and signs the launcher with the same
release certificate. Its signed Windows version resource also binds the exact
metadata SHA-256; the publisher checks that binding for both architectures and
rejects a stale launcher even when its certificate still matches. Setup verifies
its own signature, metadata, MSIX and all
script pins before enabling installation. Unsigned review launchers without
embedded metadata refuse installation. No IPC
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
one service ownership model: the bootstrap's elevated service phase provisions the
manual `sc.exe` service. A raw MSIX or `.appinstaller` registration installs or
updates only the application payload; it does not provision, repair, update, or
remove the VPN service.

Every initial install, repair, update, rollback, and uninstall must enter
through the emitted bootstrap from the versioned artifact directory, launched
as the original owning user:

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
separate `Private` subtree containing the tunnel key grants access only to
LocalSystem and Administrators. Install, repair and removal reject redirected
state paths and unexpected access rules. A
fresh 256-bit IPC credential is generated with the Windows CSPRNG and protected
using machine-scoped DPAPI. The bootstrap keeps MSIX registration, removal and
relaunch under that user's token. It elevates only the pinned service operation
with the original owner SID and checks the package registered for that owner;
another administrator's credentials do not transfer service ownership. Existing
package replacements can require two UAC prompts: stop before replacement,
then provision the new payload. Failed provisioning retains the registered UI
for verified Repair and reports failure. Rollback validates the retained release
before stopping the current service and replaces the package in place. If
registration fails, the unchanged previous package and protected service state
are verified before restarting its service. Repair stops the controller before
replacing its authorization. The bootstrap verifies release pins, protected
authorization, installed payload hashes and SCM configuration, then waits
for `VEX VPN Service` to reach `Running` before reporting success.
Removal can be retried after service cleanup has completed but MSIX removal
failed. The helper accepts that state only when both services, the owned data
directory and all owned machine pins are absent; ambiguous leftovers still
stop removal.

For a first installation, extract the complete architecture-specific release
ZIP into one directory, then open `VEX.Setup.x64.exe` or `VEX.Setup.arm64.exe`.
The native installer provides Install, Repair, Uninstall and Verify actions.
It keeps verified files locked while the bootstrap runs and requests the
standard Windows administrator prompt for service changes. The bundle must
remain complete; moving only the `.exe` discards its pinned installation inputs.

The signed public `update.json` release pairs the exact MSIX, bootstrap,
install/uninstall helpers, Microsoft framework and `package-metadata.json` URIs,
SHA-256 hashes and sizes. Publishing also emits signed `bootstrap-entry.json` plus
`bootstrap-entry.json.sig`. Update consumers must stage the MSIX, metadata, and
all three PowerShell scripts and the framework into one directory, verify
that signed entry, and launch `bootstrap-native-windows.ps1` as the owning user. It requests elevation
only for its service phases. Direct launch of the MSIX or
AppInstaller is not a complete VEX VPN installation/update path.

The native app therefore owns the Sparkle-equivalent lifecycle. Automatic
checks are enabled by default, run shortly after startup and every six hours,
back off for fifteen minutes after transient failures, and can be disabled in
Settings. A verified available release is surfaced in the tray and Update
Center; installation always stages every signed artifact and enters through
the original-user bootstrap and its verified elevated service phases. A failed
service phase does not report a successful update or remove other users' packages.
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
the architecture-specific paths before packaging. VCLibs staging uses the official
Microsoft download by default. Offline builds can set
`VEX_WINDOWS_VCLIBS_PATH_X64`/`_ARM64`; alternate HTTPS mirrors require
`VEX_WINDOWS_VCLIBS_URI_X64`/`_ARM64` and matching SHA-256 pins. Packaging verifies
Microsoft identity, signature, framework version and architecture.

PE, MSIX and bootstrap signatures are timestamped. Override the default
timestamp service with `VEX_WINDOWS_SIGN_TIMESTAMP_URI` when needed; signing
or signature verification failure stops packaging.

Each publish must also set a strictly increasing
`VEX_WINDOWS_MANIFEST_REVISION`. Set
`VEX_WINDOWS_REQUIRED_VERSION_FLOOR` when raising the persisted minimum
security floor; otherwise the publisher uses
`VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION` or `0.0.0.0`. An optional canary must
not silently raise every older client to the new release floor. Mandatory
updates use a 100% rollout; clients below a verified floor bypass the optional
cohort only when an eligible signed release satisfies that floor. Signing
requires the exact shipping P-256 public/private key pair and rejects mismatches. A floor increase
prevents later downgrade below that version, so select it before signing.

The separate Native Windows CI workflow runs portable tests plus Windows x64
and arm64 self-contained publishes for scoped PR/main changes. It verifies
published native executable architectures, compiled PRI resources, and required
application assets. On a fresh Windows x64 runner, a bounded startup smoke
launches the unpackaged UI, observes process survival for ten seconds, and
terminates it. It refuses hosts with an installed VEX service or saved session;
this startup check does not provision a service. Separate Debug-only previews
exercise authenticated and signed-out navigation, the server picker, compact
layout, single-instance redirection, close-to-tray, second-launch restoration,
maximized-window preservation, restoration from minimization through actual
shell protocol activation and clean exit. Preview state is disposable;
the Settings drill also changes and restores a local preference and leaves the
page while its status request is pending, then verifies the resumed refresh.
HTTP, realtime and service calls use offline fixtures. Release builds cannot
enable those fixtures. Their PNG captures accompany the unsigned review builds.

A macOS job renders the existing SwiftUI Home, Account, Settings, server sidebar
and sign-in screens with its native Debug renderer for visual comparison. A
separate fresh Windows x64 job qualifies the pinned AmneziaWG 3.1.0 CLI and
Wintun against a memory-only encrypted peer. It checks signed-profile admission,
SCM/adapter creation, a recent UAPI handshake, tunnel-bound DNS and verified HTTPS,
traffic counters and owned cleanup. It uses one private /32 route and leaves
AntiLeak disabled for its initial narrow-route phase. Ordinary PR/main CI and
the explicit `full_tunnel_checks=true` manual mode then verify full IPv4
routing, actual AntiLeak, tunnel DNS/HTTPS,
physical control-plane HTTPS, blocked/restored outside TCP, demand-start vendor
registration, and controller-death cleanup. Its encrypted peer has no public
Internet forwarding; actual public VPN egress, roaming and physical ARM64
acceptance remain separate. Full routing uses paired `/1` routes so the vendor
cannot apply a second `/0` firewall that blocks the VEX API escape. Signed
IPv6 assignments are materialized only when present and valid.
The same fixture exercises a unique unsigned LocalSystem SCM controller with
the real pipe server and command handler: rejected credentials and tampered
profiles, signed connection, crash/restart status restoration, durable
disconnect after restart, and graceful-stop cleanup followed by another
controller start that must remain disconnected. Its private process
attestation establishes only fixture ownership; signed installed UI-to-service
attestation and real tray clicks still require release acceptance. Production
IPC attestation remains mandatory. Runtime cleanup preserves network protection
and its journal when stopping the vendor tunnel cannot be confirmed.
See [the fixture documentation](scripts/vpn-fixture-peer/README.md).
The fixture also calls the production Windows routing interop for both OS
loopbacks to check IPv4/IPv6 structure layout, interface, next hop and source
address without changing routes or sending traffic.
An additional documentation-address host route exercises the production route
creator, actual Windows metric/protocol, durable creation receipt and confirmed
removal without sending traffic. A fifteen-second signed lease verifies
autonomous SCM/adapter/lease cleanup before any status request.

For an installed client with a real test entitlement, use
`scripts/verify-public-vpn.ps1` from elevated Windows PowerShell 5.1 or PowerShell
7. Supply the expected public IPv4 exit of the selected remote VPN server, then
record three observations on the same Windows machine within ten minutes:

```powershell
$expectedExit = @('REPLACE_WITH_REAL_VPN_EXIT_IPV4')
$verify = '.\native-windows\scripts\verify-public-vpn.ps1'
& $verify -Phase Baseline -ExpectedVpnExitIpv4 $expectedExit -ResultPath .\vpn-baseline.json
# Sign in and connect in the installed VEX application.
& $verify -Phase Connected -ExpectedVpnExitIpv4 $expectedExit -BaselinePath .\vpn-baseline.json -ResultPath .\vpn-connected.json
# Disconnect in the application.
& $verify -Phase Restored -ExpectedVpnExitIpv4 $expectedExit -BaselinePath .\vpn-baseline.json -ConnectedPath .\vpn-connected.json -ResultPath .\vpn-restored.json
```

This observer does not connect, install, alter network state, or read account
tokens/private keys. Two independent HTTPS services must agree on the public
IPv4 address. Connected observations require the owned running VEX controller
and vendor runtime, matching installed hash pins, the real `vex` adapter, and
Windows best routes through that adapter before and after both requests. The
observed exit must match the supplied remote exit and differ from baseline;
disconnect must restore baseline egress. TLS validation stays enabled, proxy
configuration and redirects are rejected, and subprocess output/time are bounded.
Phase files include machine/run identity, freshness and predecessor hashes; they
are never overwritten and retain only hashes of network addresses. They are local
observations, not signed attestations. Authentication, DNS leakage, IPv6,
failure recovery, signed installed IPC and reboot remain explicitly unverified.
Ordinary CI tests the observer's rejection and parsing behavior without using a
production session or declaring real public VPN acceptance.

Unsigned PR and manual review builds include sanitized startup, desktop and
tunnel results; private fixture keys, account state and process dumps are excluded.
Routine jobs do not access signing secrets. Manual validation needs no release
inputs; signed release preparation requires `package_release=true`, the main
branch, release version/revision/notes, and the configured release inputs.
Signed preparation fails clearly when required signing inputs are missing.
On a fresh x64 runner it also validates the actual Setup executable and installs
through its native Install button, verifies and removes that installation, then
installs a synthetic preceding package, upgrades, repairs, rolls back,
reinstalls, opens installed Account/Settings and uninstalls while preserving
shared Microsoft frameworks. This checks package lifecycle, not an upgrade from
a prior production binary. Sanitized JSON records exactly which checks passed.
Signed output is retained for review; the workflow does not promote it to a
public update origin.

Cross-platform packaging checks:

```bash
node native-windows/scripts/validate-packaging-static.mjs
```

PowerShell 7 provides the actual AST parser and release validation tests on
Linux, macOS and Windows. Network-policy tests also exercise non-enumerating
JSON-array decoding and, on Windows, invoke the service's actual Windows
PowerShell 5.1 host with its production stdin transport:

```powershell
.\native-windows\scripts\validate-powershell-parse.ps1
.\native-windows\tests\ReleaseValidation.Tests.ps1
.\native-windows\tests\InstallerSafety.Tests.ps1
```

The Windows x64 job also runs the isolated installer and bootstrap tests under
the exact system Windows PowerShell 5.1 executable used for elevated phases.

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

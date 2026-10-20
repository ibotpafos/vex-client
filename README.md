# VEX Client

Public client monorepo for VEX VPN.

This repository contains VEX client applications for desktop and mobile. It intentionally does not contain VEX backend, admin, infrastructure, deployment, or production promotion code.

## Repository Layout

- `app/`, `src/`, `assets/` - shared Expo/React Native client app.
- `macos-native/` - active standalone macOS client.
- `native-windows/` - active standalone Windows client, with WinUI 3 UI and a privileged VPN service.
- `android/`, `ios/`, `modules/` - mobile native projects and local Expo native module.

## Release Model

Native macOS uses its native build and packaging scripts; Android and iOS use
Expo/EAS. Production promotion always
stays local in the private VPN repository.

The owner reopened native Windows development on 2026-10-10 to reach native
macOS feature parity, superseding the 2026-09-25 pause. Scoped PR/main CI tests
the control-plane client and builds/publishes the WinUI application and VPN
service for x64 and arm64. Signed release preparation is manual, requires the
`package_release` input and configured signing/runtime inputs, and produces
reviewable artifacts without promoting public update metadata.

Windows release acceptance still requires a clean real-device install,
upgrade, rollback, uninstall and tunnel/DNS/route lifecycle drill. Existing
published Windows packages and update metadata remain available until those
gates pass. See [native-windows/README.md](native-windows/README.md).

Local build entrypoints keep heavy caches and generated build directories on
an external disk, then call the same per-platform scripts used by release
lanes or local-only releases.

```bash
VEX_LOCAL_RELEASE_CACHE_ROOT=/Volumes/D/projects/.dev-cache/vex/releases/vex-client npm run local:release
```

By default, `local:release`, direct Android/macOS release scripts, EAS build commands, and OTA publish commands use `/Volumes/D/projects/.dev-cache/vex/releases/vex-client`. The cache bootstrap moves ignored heavy build directories there, forces Gradle/Cargo/Go/npm/Expo/Metro/tmp caches to that path, and leaves source files in the checkout. Put signing secrets in ignored local env files such as `.env.signing.local` or `.env.local-release`.

Useful controls:

- `LOCAL_RELEASE_PLATFORMS=macos,android` limits the run to selected platforms.
- `RUN_LOCAL_RELEASE_CHECKS=0` skips `npm ci`, typecheck, and unit tests when rerunning after a clean pass.
- `VEX_LOCAL_CACHE_MOVE_EXISTING=0 npm run local:release-cache` only reports existing local build directories instead of moving them.
- `VEX_LOCAL_RELEASE_CACHE_STRICT=0` allows pre-existing cache env vars to override the external disk path. The default is strict external-disk caching.

macOS and Android can build on this macOS workstation.

## Local Checks

```bash
npm ci
npm run typecheck
npm run test:unit
npm run lint
```

Native API verification uses production Foundation code and private loopback
fixtures. With full Xcode, run the transport/profile XCTest harnesses:

```bash
TMPDIR=/Volumes/D/VEX-CI/cache/local-user/tmp/ npm run test:macos-api-transport
TMPDIR=/Volumes/D/VEX-CI/cache/local-user/tmp/ npm run test:macos-profile-identity
```

On a Command Line Tools host without XCTest, explicitly run the shared API
scenarios as a fixture executable:

```bash
TMPDIR=/Volumes/D/VEX-CI/cache/local-user/tmp/ npm run test:macos-api-contract-probe
```

The probe and XCTest share the same redirect, body deadline/cancellation and
error-reader scenarios. The probe compiles the production API/models with the
existing isolated platform stores; it does not run AppKit, access the keychain,
start the privileged helper or change VPN state. Passing it does not establish
XCTest, full-app, cryptographic, device or release acceptance. The profile harness
uses existing SwiftPM/module cache paths on D when the checkout is on D; pass
SwiftPM cache options through the transport harness when needed.

Mobile and macOS share one API configuration boundary per platform. Set
`EXPO_PUBLIC_VEX_API_BASE_URL` for Expo or `VEX_API_BASE_URL` for macOS; absent
or empty values keep `https://vexguard.app`. Absolute HTTP/HTTPS URLs support
custom hosts, local ports and path prefixes. Credentials, query strings,
fragments, relative URLs and malformed addresses are rejected. A configured
invalid address is never replaced with a production fallback.

Validation happens before native request setup, transport dispatch or PKCE
state/device access. It returns `invalid_api_base_url`, preserving a previous
PKCE attempt and avoiding outage/session-expiry classification or query retries.
Public `vexApiBaseUrl` and `trimTrailingSlash` exports remain available. Website
links, manual Android update trust and web auth reuse the same mobile source;
existing update checksum/signature rules are retained. Expo's literal
[`process.env.EXPO_PUBLIC_…` access](https://docs.expo.dev/guides/environment-variables/)
is preserved for bundler substitution.

The shared native probe now includes configuration/default/custom-prefix cases
alongside the transport scenarios. Its owned HTTP fixture uses bounded,
verified termination rather than an unbounded process wait. Mobile guards are
also exercised with Expo's installed WHATWG URL implementation.

Windows HTTP, realtime and PKCE clients reuse `VexApiConfiguration`. Windows
retains HTTPS for remote origins and HTTP only for loopback; custom path prefixes
(including escaped segments) apply consistently to each client. Invalid bases
raise an `ArgumentException` with the fixed `invalid_api_base_url` code before
HTTP, native auth or PKCE state/device access. The release origin stays pinned;
`VEX_API_BASE_URL` remains a debug-only override. Missing/empty debug values use
the shared production default. Portable .NET tests compile the real client/auth
sources and use in-memory HTTP handlers; WinUI, Windows services and real tunnel
acceptance still require Windows.

API GET retries share one total deadline, including body reads and server
cooldowns. Writes remain a single attempt. macOS API requests return HTTP
redirects as failures to the API consumer, preserving the original request.
Mobile/macOS error readers retain string `code`, `message` and legacy `error`
fields independently, preserve legacy plain/string responses, and avoid echoing
unknown JSON or HTML bodies. Windows keeps its narrower endpoint-specific
public error-code allowlist. Mobile React Native redirect behavior still needs
native-runtime qualification; setting a Fetch option alone is insufficient proof.

Native macOS release:

```bash
npm run native:macos:release
```

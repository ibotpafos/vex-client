# VEX Client

Public client monorepo for VEX VPN.

This repository contains VEX client applications for desktop and mobile. It intentionally does not contain VEX backend, admin, infrastructure, deployment, or production promotion code.

## Repository Layout

- `app/`, `src/`, `assets/` - shared Expo/React Native client app.
- `macos-native/` - active standalone macOS client.
- `native-windows/` - retained legacy Windows source; no new first-party Windows development or routine releases.
- `android/`, `ios/`, `modules/` - mobile native projects and local Expo native module.

## Release Model

Native macOS uses its native build and packaging scripts; Android and iOS use
Expo/EAS. Production promotion always
stays local in the private VPN repository.

As of 2026-09-25, the first-party native Windows app is frozen by owner
decision. Do not include it in ordinary feature work, CI or deployment plans.
Existing Windows source, packages and update metadata remain untouched while
a separate user migration/retirement decision is prepared. A one-off emergency
repair requires a new explicit owner request.
The retained manual Windows workflow does not package a release unless the
repository variable `VEX_WINDOWS_RELEASE_REOPENED` is explicitly set to `true`
after that decision.

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

Native macOS release:

```bash
npm run native:macos:release
```

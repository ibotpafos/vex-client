# VEX Client

Public client monorepo for VEX VPN.

This repository contains VEX client applications for desktop and mobile. It intentionally does not contain VEX backend, admin, infrastructure, deployment, or production promotion code.

## Repository Layout

- `app/`, `src/`, `assets/` - shared Expo/React Native client app.
- `src-tauri/` - desktop Tauri runtime used by Windows and Linux release lanes.
- `android/`, `ios/`, `modules/` - mobile native projects and local Expo native module.
- `.github/workflows/windows-release.yml` - first public release lane.
- `.github/workflows/linux-release.yml` - public Linux release lane.
- `packaging/linux/` - Linux package payloads that are safe to publish.

## Release Model

Local release builds are the primary path when GitHub Actions runner availability is blocked. Local build entrypoints keep heavy caches and generated build directories on an external disk, then call the same per-platform scripts used by release lanes.

```bash
VEX_LOCAL_RELEASE_CACHE_ROOT=/Volumes/D/Downloads/VEX/local-release-cache/vex-client npm run local:release
```

By default, `local:release`, direct Android/macOS release scripts, Tauri local builds, EAS build commands, and OTA publish commands use `/Volumes/D/Downloads/VEX/local-release-cache/vex-client`. The cache bootstrap moves ignored heavy build directories there, forces Gradle/Cargo/Go/npm/Expo/Metro/tmp caches to that path, and leaves source files in the checkout. Put signing secrets in ignored local env files such as `.env.tauri-updater.local`, `.env.signing.local`, or `.env.local-release`.

Useful controls:

- `LOCAL_RELEASE_PLATFORMS=macos,android` limits the run to selected platforms.
- `RUN_LOCAL_RELEASE_CHECKS=0` skips `npm ci`, typecheck, and unit tests when rerunning after a clean pass.
- `VEX_LOCAL_CACHE_MOVE_EXISTING=0 npm run local:release-cache` only reports existing local build directories instead of moving them.
- `VEX_LOCAL_RELEASE_CACHE_STRICT=0` allows pre-existing cache env vars to override the external disk path. The default is strict external-disk caching.

macOS and Android can build on this macOS workstation. Linux needs a Linux host or VM with the Tauri WebKit dependencies from `.github/workflows/linux-release.yml`. Windows needs a Windows host with PowerShell and the MSVC Rust toolchain.

GitHub Actions release lanes remain as a secondary path. The Windows lane builds artifacts on `windows-latest`:

- `Vex-Windows-{version}-setup.exe`
- `Vex-Windows-{version}.msi`
- `Vex-Windows-{version}.msi.zip` or `Vex-Windows-{version}.nsis.zip`
- matching `.sha256` files
- `.sig` sidecars

The updater zip `.sig` is the Tauri updater signature and is the only signature used by the production updater contract. Installer `.sig` files are checksum metadata only; Authenticode code signing is not part of the v1 public build.

GitHub Actions builds Linux artifacts on `ubuntu-24.04`:

- `Vex-Linux-{version}.AppImage`
- `Vex-Linux-{version}.deb`
- matching `.sha256` files
- `.sig` sidecars

The AppImage `.sig` is the Tauri updater signature used by the production updater contract. The `.deb` package includes the public `vex-vpn-linux-helper` payload and sudoers drop-in for systems that install the Debian package.

Production promotion stays in the private VPN repository. Public workflows never call VEX admin APIs and never update production updater settings directly.

## Required GitHub Secrets

Configure these repository secrets before running the release workflow:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- `TAURI_SIGNING_PUBLIC_KEY`

## Local Checks

```bash
npm ci
npm run typecheck
npm run test:unit
cargo check --manifest-path src-tauri/Cargo.toml --target x86_64-pc-windows-msvc
```

The full Windows release build requires Windows:

```powershell
npm run windows:release
```

The full Linux release build requires Linux with Tauri system dependencies:

```bash
npm run linux:release
```

## Windows GitHub Release

Push a tag named `windows-v{version}` to build and publish a GitHub Release:

```bash
git tag windows-v0.1.28
git push origin windows-v0.1.28
```

## Linux GitHub Release

Push a tag named `linux-v{version}` to build and publish a GitHub Release:

```bash
git tag linux-v0.1.28
git push origin linux-v0.1.28
```

# VEX Client

Public client monorepo for VEX VPN.

This repository contains VEX client applications for desktop and mobile. It intentionally does not contain VEX backend, admin, infrastructure, deployment, or production promotion code.

## Repository Layout

- `app/`, `src/`, `assets/` - shared Expo/React Native client app.
- `src-tauri/` - desktop Tauri runtime used by Windows first, with macOS/Linux lanes kept private until they are ready here.
- `android/`, `ios/`, `modules/` - mobile native projects and local Expo native module.
- `.github/workflows/windows-release.yml` - first public release lane.

## Release Model

GitHub Actions builds Windows artifacts on `windows-latest`:

- `Vex-Windows-{version}-setup.exe`
- `Vex-Windows-{version}.msi`
- `Vex-Windows-{version}.msi.zip` or `Vex-Windows-{version}.nsis.zip`
- matching `.sha256` files
- `.sig` sidecars

The updater zip `.sig` is the Tauri updater signature and is the only signature used by the production updater contract. Installer `.sig` files are checksum metadata only; Authenticode code signing is not part of the v1 public build.

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

## Windows GitHub Release

Push a tag named `windows-v{version}` to build and publish a GitHub Release:

```bash
git tag windows-v0.1.28
git push origin windows-v0.1.28
```

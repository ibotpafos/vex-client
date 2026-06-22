# VEX Windows Client

Public Windows desktop client for VEX VPN.

This repository builds the Windows Tauri client and publishes release artifacts. It intentionally does not contain VEX backend, admin, infrastructure, deployment, or production promotion code.

## Release Model

GitHub Actions builds Windows artifacts on `windows-latest`:

- `Vex-Windows-{version}-setup.exe`
- `Vex-Windows-{version}.msi`
- `Vex-Windows-{version}.msi.zip` or `Vex-Windows-{version}.nsis.zip`
- matching `.sha256` files
- `.sig` sidecars

The updater zip `.sig` is the Tauri updater signature and is the only signature used by the production updater contract. Installer `.sig` files are checksum metadata only; Authenticode code signing is not part of the v1 public build.

Production promotion stays in the private VPN repository. The public workflow never calls VEX admin APIs and never updates production updater settings directly.

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

## GitHub Release

Push a tag named `windows-v{version}` to build and publish a GitHub Release:

```bash
git tag windows-v0.1.28
git push origin windows-v0.1.28
```

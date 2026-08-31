# IBO-180 production signing CI

## Objective

Provide one reproducible, fail-closed GitHub Actions entrypoint that builds the
native macOS release with the existing Sparkle trust chain, Developer ID
Application and Installer identities, notarizes and staples the app, verifies
the immutable release bundle, and exposes it for the separately controlled
production-download deployment.

## Scope

- Manual release workflow on a hosted macOS runner.
- Ephemeral keychain import for Application and Installer PKCS#12 identities.
- Secret-file materialization for the existing Sparkle Ed25519 private key.
- Apple notarization through an explicit notarytool profile.
- Existing release scripts remain the single implementation path.
- The workflow builds and verifies release artifacts; it does not mutate the
  public appcast or active VPN state.

## Contracts and invariants

- Production release mode always requires Developer ID and notarization.
- Missing or empty signing inputs, including the production-repository token,
  stop before any secondary repository checkout or release build.
- Private keys, certificate material, passwords, and profiles never appear in
  workflow output or uploaded artifacts.
- The temporary keychain and materialized secrets are deleted in an `always()`
  cleanup step.
- Sparkle private/public keys are mechanically matched by the existing release
  verifier before the artifact is accepted.
- The produced manifest must report Apple Developer signing, notarization, and
  Gatekeeper readiness as true.

## Scenarios

1. A manual run with every configured secret imports both identities, builds,
   notarizes, staples, verifies, and uploads the deploy bundle.
2. A missing secret fails the input gate without starting a release build.
3. An ad-hoc signature or missing ticket fails the production preflight.
4. Cleanup removes the temporary keychain and secret files after success or
   failure.

## Acceptance criteria

- Contract tests reject a workflow without the full secret gate, temporary
  keychain cleanup, production flags, or artifact upload.
- Autonomous release passes `VEX_NATIVE_PRODUCTION=1`, Developer ID required,
  and notarization required through every preflight.
- Shell syntax, workflow YAML parsing, release policy tests, and diff checks
  pass.
- A real release run remains gated on the matching external signing inputs.

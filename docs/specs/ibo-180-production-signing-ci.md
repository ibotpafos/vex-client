# IBO-180 production signing CI

## Objective

Provide one reproducible, fail-closed GitHub Actions entrypoint that builds the
native macOS release with the existing Sparkle trust chain and the project's
pinned self-signed application identity, verifies the immutable ZIP bundle,
and exposes it for the separately controlled production-download deployment.

## Scope

- Manual release workflow on a hosted macOS runner.
- Ephemeral keychain import for the pinned self-signed Application PKCS#12 identity.
- Secret-file materialization for the existing Sparkle Ed25519 private key.
- Mechanical verification that the signing certificate is self-issued and its
  SHA-256 fingerprint matches the configured public pin.
- Existing release scripts remain the single implementation path.
- The workflow builds and verifies release artifacts; it does not mutate the
  public appcast or active VPN state.

## Contracts and invariants

- Production release mode requires the pinned self-signed identity and rejects
  ad-hoc, Developer ID, and unpinned certificates.
- Missing or empty signing inputs, including the production-repository token,
  stop before any secondary repository checkout or release build.
- Private keys, certificate material, passwords, and profiles never appear in
  workflow output or uploaded artifacts.
- The temporary keychain and materialized secrets are deleted in an `always()`
  cleanup step.
- Sparkle private/public keys are mechanically matched by the existing release
  verifier before the artifact is accepted.
- The produced manifest must report self-signed distribution as true and Apple
  Developer signing, notarization, and Gatekeeper readiness as false.

## Scenarios

1. A manual run imports the pinned self-signed identity, builds, signs, verifies,
   and uploads the ZIP-only deploy bundle.
2. A missing secret fails the input gate without starting a release build.
3. An ad-hoc, Developer ID, or wrong self-signed certificate fails preflight.
4. Cleanup removes the temporary keychain and secret files after success or
   failure.

## Acceptance criteria

- Contract tests reject a workflow without the full secret gate, temporary
  keychain cleanup, production flags, or artifact upload.
- Autonomous release passes `VEX_NATIVE_PRODUCTION=1`, `self-signed` signing
  mode, and the certificate pin through every preflight.
- Shell syntax, workflow YAML parsing, release policy tests, and diff checks
  pass.
- A real release run remains gated on the matching external signing inputs.

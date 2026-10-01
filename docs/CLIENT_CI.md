# Client CI

Owner decision, 2026-10-01: Android, macOS and web only. There is no active
iOS application; Windows remains paused. Standard GitHub-hosted Actions for the public
`ibotpafos/vex-client` repository; no new local runner registration.

Native Reliability CI validates PRs from this repository, main changes and
manual runs. Fork PR code is rejected at job level. All jobs use read-only
permissions and credential-free checkout, pinned official actions, bounded
timeouts and no production/signing secrets or routine binary artifact uploads.
No dependency-cache upload is configured. Standard public-repository runner
compute is free; larger runners and storage exceeding the applicable quota
are not covered by that statement.

- Shared: unit/upstream contracts, TypeScript, ESLint, CI contract negative
  fixtures, pinned/checksummed actionlint and production web export.
- Android: JDK 17, SDK 36, NDK 27.1.12297006, pinned upstream sources, debug
  arm64 APK build plus package/version/ABI verification and all debug unit tests.
- macOS: native app compilation and affected Swift suites; no helper install
  and no modification of the developer host's active tunnel.

CI compilation is not evidence of a signed install, real-device Network
Extension/VPN recovery, Doze/process-death behavior or a zero-leak guarantee.
iOS and Windows sources/manual workflows stay untouched; neither gets a routine
CI job. Existing manual release workflows and publication approvals remain separate.
No production deployment or release is triggered by these checks.

References:
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://docs.expo.dev/versions/v57.0.0/
- https://github.com/rhysd/actionlint/releases/tag/v1.7.12
- https://eemeli.org/yaml/

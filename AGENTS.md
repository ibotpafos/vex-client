# Expo documentation when relevant

When changing Expo APIs, SDK configuration, native integration, or SDK migration
behavior, use `dependencies.expo` in `package.json` to select the SDK version.
For SDK 58, consult [the versioned Expo reference](https://docs.expo.dev/versions/v58.0.0/).

For isolated copy, styling, documentation, routine commands, or native code
that does not depend on Expo, choose the relevant files, tools, and checks
without requiring an Expo documentation lookup first.

# Platform scope

Owner decision (2026-10-10): native Windows development is reopened to deliver
a complete first-party application with native macOS feature parity. Work in
`native-windows/` and scoped, unsigned Windows build/test CI is authorized.
The previous pause (2026-09-25) remains part of the decision history.

Keep existing published artifacts and update metadata intact until a release
passes Windows install/upgrade/rollback/uninstall and real tunnel acceptance.
Signing and release preparation belong to an explicit manual workflow;
production promotion remains in the private VPN repository.

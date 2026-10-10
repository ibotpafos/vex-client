# Expo HAS CHANGED

Read the exact versioned docs at https://docs.expo.dev/versions/v56.0.0/ before writing any code.

# Platform scope

Owner decision (2026-10-10): native Windows development is reopened to deliver
a complete first-party application with native macOS feature parity. Work in
`native-windows/` and scoped, unsigned Windows build/test CI is authorized.
The previous pause (2026-09-25) remains part of the decision history.

Keep existing published artifacts and update metadata intact until a release
passes Windows install/upgrade/rollback/uninstall and real tunnel acceptance.
Signing and release preparation belong to an explicit manual workflow;
production promotion remains in the private VPN repository.

# Dependency cleanup verification — 2026-10-23

This change removes unused EOAS3 development tooling and 216 lock entries.
Publishing scripts retain the explicitly pinned compatible `eoas@2.3.23`
command. Publisher executable lines are unchanged; no OTA publication was run.

Three retained dependencies move to reviewed patched versions: MCP classic SDK
1.32.1, ip-address 10.7.4 and source-map-js 1.2.2. Expo SDK57, React Native,
application version 1.0.73 and runtime configuration stay unchanged.

Removing the old tooling exposed implicit imports of `@expo/config` and
`@expo/config-plugins`. Tests and both active native plugins now use the public
`expo/config` and `expo/config-plugins` SDK entrypoints, following the
[Expo plugin documentation](https://docs.expo.dev/config-plugins/plugins/).
Plugin bodies otherwise match the parent after reversing the import path.

Verified locally on a clean, owned install:

- Full `npm run check` passed, including unit, AWG upstream, type, lint,
  client CI and release-policy checks.
- A new regression loads both real plugins and checks mod registration without
  running native-writing callbacks. It fails with the old imports and passes
  with the public SDK imports; all three dependency tests pass.
- `expo config --type prebuild --json` loaded the SDK57 configuration with
  updates disabled. Mods were registered without execution; 144 tracked native
  and configuration files were unchanged.
- Read-only source review verified all seven source-file hashes at entry and
  exit, confirmed the plugin import fix and found no new actionable defects.

Full npm audit still reports five high package chains for the single underlying
[node-forge advisory](https://github.com/advisories/GHSA-86w9-cpqp-85rv).
The registry has no patched release on this date; latest 1.4.0 is affected.
This finding remains visible. A nearby publisher TODO records the need to
qualify the certificate path when a maintained fix is available. No audit
suppression, forced Expo downgrade or signing-policy change was made.

The lock audit does not qualify the separately downloaded pinned publisher
graph. Local portable checks and configuration loading do not establish native
build, certificate, OTA or tunnel acceptance. Exact-head platform CI for the new
commit is tracked separately in the draft pull request.

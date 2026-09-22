# macOS photo design integration — 2026-09-22

The user identified that build 119 omitted the newer design. Integrate the
uncommitted design from `codex/macos-photo-locations-20260909` (base `e3d3906`)
into the consolidation branch without modifying that source worktree.

## Result

- Restore the full-width country photograph, compact central power control,
  three photographic cards and the revised spacing from the accepted design.
- Include the existing Frankfurt, Helsinki and Amsterdam PNG assets.
- Preserve current country grouping, aggregate availability and original node
  IDs. Selecting a country uses its representative; selecting the current card
  opens the node chooser. Keep card order stable while selection changes.
- Retain country-resource startup fixes, fail-fast builds, confirmed helper
  teardown, AWG 3.1, realtime and account/device changes from build 119.
- Reuse the existing preview renderer in release builds only when runtime is
  suppressed. Offline smoke uses synthetic locations and no recovery timer;
  it never restores a session or starts the helper/updater.
- Check all three photographs in the packaged resource probe.

## Verification

Build 120 is a local ad-hoc candidate. Release compilation passed for arm64 and
x86_64. The focused country/layout regression passed: aggregation, original
IDs, offline nodes, stable card order, three-column widths and Reduce Motion.

- `codesign --verify --deep --strict` passed. App and helper are universal.
- Packaged resource probes passed for country geometry and all three photos.
- The relocated-app regression passed; removing its resource bundle still
  fails cleanly without a crash or fallback to build-cache assets.
- Offline launch smoke passed for 45 seconds with no crash reports and the
  same process (14266). Helper and update runtime were disabled.
- [The release executable's offline render](macos-photo-design-120.png) was
  inspected against the original design reference. Its photographic coverage
  test passed at 5.76%. The bitmap renderer does not composite the macOS 26
  glass dock, so that part was checked in the live window instead.
- Native UI screenshot inspection succeeded for the open build 120 window:
  Frankfurt hero, Germany/Finland/Netherlands photo cards, version label and
  bottom navigation are visible. Controls are intentionally disabled by the
  offline smoke mode. No live connection interaction was performed.
- Executable SHA-256:
  `4319a6433a91cf12026a6029f3c70ae30d5dc8d7b9d077271f853654d56af700`.

The artifact remains at `macos-native/build/VEXNativeMac.app`, version
**0.1.88 (120)**, and was left open in offline mode.

No VPN connection or helper installation is authorized in this task. Existing
XCTest, trusted-signing and real tunnel qualification limits still apply.

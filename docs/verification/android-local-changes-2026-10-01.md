# Android local-change reconciliation — 2026-10-01

## Confirmed released baseline

- Published Android1.0.60/1006068 compiles6592a57248767190367e3ca4e353b5b95d330ea6.
- Current remote main6e629597aaa4f313f1c8dd35e8b9dfc0c04d290c differs from that source only in versions.json and release documentation. Native/app code matches the published build.
- The old working-tree checkpoint7f040c52bb9080ecc932b4104081d98a78f9ea57 is NOT the current release source; do not build or publish it wholesale.

## Local work that is not proven released

The checkpoint still has absent-from-main standalone modules: boot-screen-presentation, home-screen-state, settings-control-policy, settings-remote-config-cache, entitlementRevocation and vpnQueryCacheCore, plus splash-wordmark artwork. These include boot presentation, settings UI/config caching and persistent-cache freshness work. Some are refactors of functionality already present in current main (for example VPN status equality); file absence alone is not proof that a user feature is missing. Port each material behavior independently onto main with regression/device checks rather than restoring old application files.

The old Android device test checkout has50 dirty Android/shared files:20 byte-identical to current main and30 different. Every source path already exists in main. Differing files include older pre-native-loss-fix WireGuardController, runtime/config/package versions and UI experiments. Treat these as quarantined variants, not automatic merge candidates. Separate package-migration checkout differs only in local Google services configuration; do not publish local config or customer diagnostics.

## Branch/worktree policy

- Audit covers40 local branches and30 registered worktrees. Twenty branches have patch-unique history, but historical conflict-resolved/squashed ports are not proven missing from a release merely by git cherry. The exact list is retained privately with source-hash evidence.
- Open PR53 is an Android observability gate; retain it for current-source contract reconciliation. PR54/55/48 are other platform work and are not merged by this Android cleanup. Native Windows remains outside active owner scope.
- Preserve every ref and dirty file; no hard reset, branch/worktree deletion, log deletion, account mutation or production publication is part of this cleanup.
- Private backups include a verified all-ref Git bundle and hash-verified selected dirty files. No backup, raw log, screenshot, generated helper binary, customer identifier or local configuration is committed here.
- Ignore only private QA capture directories and root generated Codex screenshots. Tracked resources remain tracked; Android source/assets are not globally ignored.

## Next scoped work

1. Reconcile PR53 observability contracts against current signing/build scripts.
2. Review the checkpoint settings, cache freshness and startup changes individually; carry useful behaviors forward with current dependencies and invariants.
3. Keep the current signed native-loss fixes and installer safeguards; no old branch may overwrite them.

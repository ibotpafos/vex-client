# Android Bugsink release correction — 2026-10-01

The published 1.0.60 APK has no configured Bugsink DSN in native DEX or its
JavaScript assets. Connection telemetry is a separate VEX pipeline; this is
not evidence of a VPN outage. Reuse the maintained Sentry SDK already installed.

The production build now requires the approved owned-project DSN in both
native DEX and the Expo Hermes/JS bundle. Reject absent configuration, malformed
URLs, alternate hosts/projects/keys, and partial SDK configuration. Do not print
ingestion keys. Explicitly disable default PII and session/tracing collection.
Use production environment and an Android version/versionCode release label.

The existing project was read through Bugsink's installed bugsink-manage CLI;
the original manage.py path failed and was corrected. The DSN is supplied only
as an existing repository build secret, never committed. EAS production Android
keeps the same gate; iOS and preview are not changed by this production gate.

Version 1.0.61/build 69 is an unpublished native candidate. Its digest and
signature URL remain empty until the signed artifact is verified; never reuse
1.0.60's checksum for this version. Production metadata stays at 1.0.60 until
an exact-run, original-certificate promotion succeeds.

Local npm run check passed, including the expanded observability contract.
A native-only fixture passed the old gate (exit 0), fails the new gate (exit 2),
and passes after portable rollback (exit 0). All pristine hashes were restored;
the binary patch reconstructs the modified copy. These are fixture results,
not proof of customer ingestion, native startup, or whole-process leak safety.

The divergent 7f040c52 checkpoint is not merged wholesale: it removes current
customer realtime/account/quota behavior and replaces stricter persistent cache
policies. Cosmetic animations and optional single-flight helpers are deferred;
missing helper filenames do not establish missing functionality. Preserve old
branches, source backups and private device captures; do not commit binaries,
customer identifiers, credentials or logs.

The retained native backend DOWN fix remains unchanged: baseline Disconnected
without blocker; modified Blocking with blocker; rollback returns to baseline;
explicit manual disconnect works in all three. Process-death/OS lockdown and
modern authenticated Doze acceptance are not claimed.

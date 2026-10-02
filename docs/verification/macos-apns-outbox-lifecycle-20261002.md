# macOS APNs outbox lifecycle — isolated candidate

Baseline native3dec359, backendfca35f. Actual pending offline runtime shows the APNs HTTP sender classifies terminal410 but the app outbox rejects an APNs target before sending (FCM-only gate). No live APNs or production observation.

Next implementation expands native managed AWG macOS eligibility without changing legacy FCM, binds queued events to owner/provider/registration revision, and settles terminal rejection with claim-fenced exact registration CAS. APNs410 timestamp must be interpreted separately from error classification: an older or missing invalidation timestamp cannot authorize clearing a newer/unknown registration.

All tests use generated ephemeral fixture keys, custom HTTP transport and fake stores/SQLmock. No provisioning key is read; no live API/DB migration/APNs call, app/helper install/launch or VPN/route/DNS/PF/user-store change. The paired backend remains isolated until approved deploy. DeveloperID/notarization/public-server-key match and real delivery/install/connect/update/leak acceptance are not proved by offline gates.

Native global lost-receipt/late-POST registration operation reconciliation, signed domain/per-app routing and throwing recovery remain explicit full-goal requirements. Android parity is not declared complete.

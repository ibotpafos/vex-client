# Tester program integration

The settings screen opens the authenticated website flow at
`/dashboard/testing`. Applications, review, free access and feedback are owned
by the API and account website; no second membership state is stored locally.

Update and remote-config requests pass the current access token through the
existing transport authorization option. Tokens never enter JSON request
bodies or React Query keys. `X-Vex-Account-Updates: 1` lets the new API select
the account's opted-in release channel, including returning an installed beta
binary to stable discovery after opt-out, expiry, revocation or logout.
Older APIs ignore this header and receive unchanged JSON.

The update query key includes the nonsecret session revision. Session guards
before and after asynchronous calls prevent a previous account's response
from being displayed after logout or account replacement. Remote settings
have the same identity guard. Per-account remote capabilities are exposed as
`accountFeatureFlags`, separately from signed shared `featureFlags`.
Account-aware remote-config requests retain the stable shared configuration,
including when the installed binary was compiled for beta.

Experimental updates remain optional. Existing native signature/checksum,
compatibility, install and rollback checks continue to apply. This integration
does not publish binaries, change Expo OTA channels or install a build silently.
Desktop platforms can use the account's curated download list; this change
does not claim integration with every separate desktop updater.

Validation: `npm run typecheck`, `npm run test:unit`; the tester session tests
exercise the real API mapper and update query with inert transport/hook mocks,
including late response and login/logout identity transitions. No VPN tunnel,
route, DNS or production credential is used by these tests.

Ship the corresponding server/web tester program before qualifying a new
mobile build. Actual signed installation and live tunnel acceptance remain
part of the normal client release workflow.

# Android functional QA — 2026-09-29

Scope: local development APK on the attached Android 9 Mi A1 (`com.vexguard.app.dev`), plus privacy-safe aggregate VEX MCP telemetry. The production package, customer accounts, servers and release channels were not changed. This matrix is not a claim of complete Android-version or network coverage.

| Area | Evidence | Result / limit |
| --- | --- | --- |
| Launch and navigation | Dev APK installed; home, settings, location picker and per-app routing screens opened on device | No observed crash; account/support external links and sign-out were not exercised |
| VPN connect/disconnect | Device showed connected state with OS `TRANSPORT_VPN` and `VALIDATED`; disconnect left zero VPN transports | Normal Wi-Fi path passed; one device, no strict data-plane probe in this cycle |
| Auto-connect | Prior device cycle and `android-auto-connect-effect.test.cjs` | Start, success, synthetic failure and pre-start cancellation covered; other Android versions not tested |
| Smart routing | Prior device cycle: Russian test address excluded with smart ON, foreign address tunneled; both tunneled with smart OFF | Behavior observed on Wi-Fi only; regional rule quality is not established globally |
| Location choice | Expanded Germany, selected a manual location, saw it on home, restored automatic selection | UI selection passed; live fallback 404 and pilot-node faults were not injected |
| Per-app routing | Search filtered to Chrome; selected-only with no apps showed a warning; prior cycle confirmed selected UID in Android VPN | Empty selection was not saved; restored all-app mode |
| Settings | Auto-connect OFF, smart ON, automatic server ON, anti-leak ON after tests | Toggle state restored; anti-leak was not fault-injected |
| Language | Before: English could be selected and persisted, but screen remained Russian. After: picker removed and honest Russian-only notice visible | Fixed misleading setting; this is **not** an English translation |
| App-list layout | Before: page title repeated in header and content. After: one title, controls higher on screen | Device-visible space improvement; no route/API change |
| Wi-Fi interruption | Temporarily disabled/re-enabled Wi-Fi in a guarded test; OS and UI showed a validated VPN again after restoration | Underlay and UI acceptance only, not proof of uninterrupted data-plane traffic |
| Updates, authentication, notifications | `npm run check` contract/unit suites | Static/synthetic coverage only; live OTA, login/logout, permission and store-update flows not exercised |
| Runtime log | Current dev process logcat after new APK: 0 `FATAL EXCEPTION`, 0 `ReactNativeJS: Error`, 0 `AndroidRuntime:` in 335 lines | Bounded local sample, not a user-crash census |
| User telemetry | Full 24-hour MCP audit: 337/337 reports, 137 diagnostic reports from 10 users/9 devices; 9 failed diagnostic reports | Sampled reports, **not** connection-attempt success rate; node/subscription failures require separate protected-case follow-up |

Verification: `npm run check` passed (unit, AmneziaWG upstream, TypeScript and ESLint); `npm run android:build:local:fast` succeeded; `adb install -r` succeeded. Development APK SHA-256: `2e2c5064fb715aad7e667c6c3058b742de61e6759319963e0dadc5e312e13e6d`. The testing APK was disconnected at the end, Wi-Fi enabled, and the production package untouched. Source-copy baseline/modified/rollback records live under `/private/tmp/vex-android-unlimited-20260929/full-qa/`.

Remaining acceptance before production: (1) Android 13–16 plus cellular/roaming/captive-portal and reconnect data-plane probes; (2) live update, auth and notification permission journeys with test accounts; (3) privacy-approved Bugsink and exact customer error triage; (4) release-gated install/update and post-update verification. Do not delete current diagnostic evidence while cases are open.

# Mobile JavaScript API origins

`EXPO_PUBLIC_VEX_API_ORIGIN` configures the API transport separately from the
legacy `EXPO_PUBLIC_VEX_API_BASE_URL` website/auth callback setting. Production
transport always starts at `https://api.vexguard.app`; its only reserve is
`https://api2.vexguard.app`. Either production API value selects the same ordered,
source-fixed pair. An explicit localhost/127.0.0.1/IPv6-loopback origin remains an
isolated development proxy with no production failover. A legacy localhost base
takes precedence over the production API setting to preserve `web:prod-auth`.
Other configured origins, credentials, ports on production hosts, paths, query
strings and fragments are rejected.

The legacy exported `vexApiBaseUrl` remains `https://vexguard.app` for existing
web login/callback consumers. Public website links, billing returns and relative
artifact download/signature URLs remain canonical. API transport selection is
internal to `rawRequest`. Realtime uses the separate `realtimeApiBaseUrl`: a
configured loopback proxy stays local for SSE bearer requests, while production
SSE retains the canonical website origin. Native-routing consumers of the legacy
export are outside this JS change.

GET requests may switch to reserve only after a network error or an attempt
timeout. HTTP replies never cause cross-origin failover: authentication denials,
maintenance, revocation and limits retain server authority. Existing bounded
same-origin GET retries and Retry-After remain in place. A received HTTP failure
locks the origin even if its body fails. `Retry-After` is captured with status at
headers and retained if the body fails or either attempt/overall deadline expires. Every new operation starts at primary,
so recovery is deterministic without sticky fallback state.

Before any production mutation, an unauthenticated GET `/v1/billing/plans`
selects a reachable origin. The probe carries no bearer, caller headers, device
identity, idempotency key or body. HTTP probe failures stop selection; only
network failures/timeouts may try reserve. The mutation is then sent once to the
selected origin with its original body and idempotency key. No mutation replay is
introduced. Web/iOS local proxies skip selection. Android mutation transport
accepts production HTTPS origins only; a loopback configuration fails before
metadata/probes/credential I/O with `native_mutation_origin_unsupported`. Probes, metadata, attempts, backoff,
body reads and the single mutation share the caller's one overall deadline
(default 30 seconds), including caller cancellation. Primary GET attempts use at
most 8 seconds or half the remaining budget; selection probes use at most 4
seconds and reserve time for the actual mutation.

Android unsafe methods (other than GET/HEAD/OPTIONS) require the additive
`apiMutationNoReplay: true`, `requestApiMutation` and `cancelApiMutation` native
contract before any probe or credential setup. The mutation ABI uses default
routing, disables automatic network retry and makes its body one-shot; it never
falls back to Expo Fetch or profile recovery. Missing capability fails closed
with `native_transport_update_required`. **This new JS requires a new compatible
Android binary for mutations.** Existing released clients are unchanged; do not
ship this JS to an older Android runtime as an OTA compatibility shortcut. Native
bridge compilation and physical QA remain on hold. iOS mutations continue to use
Expo Fetch with redirect rejection.

Native ordinary read requests explicitly import `fetch as expoFetch` from
`expo/fetch`, using `redirect: 'error'` and `credentials: 'omit'`. They do not use
RN global Fetch/XHR, including when `EXPO_PUBLIC_USE_RN_FETCH=1`. SDK 57 Android
sets both OkHttp redirect flags false; iOS rejects the redirect delegate's next
request before sending. Final-response URL checks are defense in depth, not the
credential boundary. Native API debug logging is disabled; web debug output does
not contain query strings, bodies or raw error payloads.

- [Expo SDK 57 Fetch API](https://docs.expo.dev/versions/v57.0.0/sdk/expo/#expofetch-api)
- [Android NativeRequest redirect controls](https://github.com/expo/expo/blob/sdk-57/packages/expo/android/src/main/java/expo/modules/fetch/NativeRequest.kt)
- [iOS NativeResponse redirect delegate](https://github.com/expo/expo/blob/sdk-57/packages/expo/ios/Fetch/NativeResponse.swift)

The existing Android profile recovery transport uses an optional native
`apiRecoveryHosts` constant containing hostnames. JS intersects that advertisement
with its fixed first-party list. Old binaries without the constant retain their
legacy policy (`vexguard.app`, `www.vexguard.app`, `api.vexguard.app`), so api2 uses
ordinary Expo Fetch there. New binaries can advertise `api2.vexguard.app` and keep
reserve requests on recovery transport. When `apiRecoveryPreservesHttpErrors` is absent/false, a generic native recovery
failure is terminal `recovery_status_ambiguous`: JS cannot infer whether an old
bridge lost an HTTP denial while reading its body. New native recovery advertises
the guarantee and preserves status/headers with an empty body on read failure.
All native recovery attempt/overall timeouts are nevertheless status-ambiguous
and terminal, including on new binaries: its buffered promise cannot expose
possibly received denial headers while a body is still pending. Only explicit
pre-header network failures under the new guarantee can fail over.
These terminal codes are not retried by the HTTP layer or TanStack Query. No generic
native failure is interpreted as a capability probe. Native policy/advertisement source changes are included.
Android bridge compilation and physical acceptance remain deferred under the
release hold.

API hosts never become trusted update hosts. Manual artifact validation and
installation retain `https://vexguard.app`; Expo OTA keeps its independent
manifest host (`https://updates.vexguard.app/manifest`) and signing configuration.
Changing the API setting cannot authorize APK/signature downloads from API hosts.

Run `npm run test:api-dual-origin` for the focused mocked contracts; the new suite
also runs at the start of `test:unit`. Tests cover pre-VPN reads, cold login/device
registration, primary recovery, total deadlines/abort, denial/maintenance/limits,
non-replay/idempotency, redirect transport choice, safe paths and artifact trust.
These checks do not establish production DNS, reserve ingress, native physical
acceptance, APK/OTA or release readiness.

Validation on 9 November 2026: 160 focused JS regressions passed using `tsx --test`
for the dual-origin, request-deadline, query-retry, recovery-transport and tester
update-session and realtime-session suites. `tsc --noEmit --incremental false` and ESLint on the seven
changed API/realtime modules passed. `native-routing` passed
`go test -race -count=1 -timeout 45s .` with in-memory networking. Six pure
policy cases and twelve HTTP safety JVM cases (18 total) passed using cached
Kotlin 2.1.20, JDK 17, JUnit 4.13.2 and actual OkHttp 4.12.0. The control
reproduces an automatic 503 POST resend; the protected client sends once for
408/503, with empty/populated bodies, and retains error headers through body
failure, timeout and cancellation. Run `npm run test:api-http-jvm`; the runner
never installs dependencies or invokes Gradle and uses only ephemeral loopback
sockets. The React Native Android bridge was source-contract checked, not
compiled; no Gradle/APK/native app build, install, device or OTA action ran.

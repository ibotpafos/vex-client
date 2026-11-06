# Android profile recovery after failed Smart routing

Android 1.0.90 on a physical Android 9 device failed an All apps / Smart routing connection: the cached AWG handshake timed out, then the fresh profile API request failed while the app UID remained inside the failed tunnel. The initial handshake failure is not attributed to a verified root cause. VLESS Wi-Fi acceptance passed independently; it does not qualify the subsequent Android candidate.

Android 1.0.91 routes automatic fresh-profile recovery requests to the first-party HTTPS API over a newly selected non-VPN Android Network. DNS and sockets use that same Network. It retains the existing VPN capture and does not bind the process or change system routes. Ordinary requests and older native binaries retain the established transport.

The native boundary restricts hosts and API paths, rejects redirects, preserves TLS configuration, isolates connection pooling, and bounds response size, concurrency and the original request deadline. JS cancellation cancels native I/O; HTTP errors and Retry-After remain visible to the caller. No credentials, response bodies or URLs are written to the recovery log marker.

Local validation: full unit suite, TypeScript, lint and upgrade/release contract checks passed. The transport and policy compile against the installed Android/RN/OkHttp dependencies; four policy JVM tests passed. The installed React Native URL implementation supports the getters used by the allowlist. Full native CI and signed Android 1.0.91 device acceptance are still required.

Release acceptance must cover AWG All apps / Smart routing, recovery after a failed cached connection while protection remains active, selected-app bypass, background connection, short and long Wi-Fi loss, VLESS, protocol switching and explicit disconnect. Confirm real HTTPS and fresh DNS from ordinary app UIDs, recovery marker execution, no direct traffic from protected app UIDs, unchanged account data after upgrade, and no new owned crash/ANR markers. Mobile-data handoff remains untested because the test phone has no mobile service. The Android 1.0.90 publisher remains held after its failed AWG acceptance; do not transfer its positive results to 1.0.91 or publish it.

## Android92: obsolete blocker after routed AWG recovery

Signed91 passed actual All/selected HTTPS and fresh DNS plus short/45s Wi-Fi recovery for AWG and VLESS on Mi A1. Its final AWG All/background repeat still reported blocking after10s foreground settling. Owned services showed the old blocker alive beside the working routed AWG service. Native activation skipped blocker retirement for routed profiles, leaving the blocker active flag authoritative in status.91 publication was rejected; no91 news or production delivery was performed.

Routed activation now checks native capture AFTER successful backend UP before awaiting obsolete blocker retirement. Failure propagates into existing activation failure handling, preserving capture or restoring the blocker. Status reporting keeps its existing authority. Four JVM cases cover retirement order, absent replacement capture, stop timeout, and cancellation. This is source/JVM coverage; physical92 and signed artifact acceptance remain required.

Version92 counter1 produces versionCode1009201, greater than91/1009199; the supported counter range1..99 is preserved. iOS metadata is unchanged.

Local validation92: full JS units, typecheck, lint, four compiled JVM handover tests passed. Release contract suite initially failed in an existing macOS fixture because the system true binary has a CPU subtype rendered as unknown by lipo; the test now compiles known arm64/x86_64 fixture slices and retains actual codesign/hash verification. This changes only test setup.

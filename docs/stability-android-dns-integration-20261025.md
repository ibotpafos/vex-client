# Android/DNS source integration, 25 October 2026

The stability branch reuses the existing `codex/dns-stream-recovery-20261024`
head `233dc4a58d7b778eeb43bd212e85f001511266b4` through a history-preserving
merge into `b8af0383b48a520436872851e75f49b694264874`. This avoids implementing
the same Android recovery and DNS fixes in parallel. The imported verification
records describe their original candidate sources and bounded device fixtures;
they do **not** qualify this combined source or constitute a new release.

## Reused behavior

- TCP DNS reconnects once after an incomplete stream, within the original
  cancellation context and total deadline. Idle UDP DNS mappings retire sooner
  so completed requests release flow capacity. Physical DNS fallback is unchanged.
- The licensed local AWG network adapter waits for admitted notification callbacks
  before closing its channels. Dial cleanup closes successful losing connections
  and never calls a method on a failed dial's typed-nil connection.
- Android traffic confirmation belongs to the admitted peer and physical network.
  DNS/HTTPS proof expiry or failure revokes the green status. Boot protection and
  idle leak-blocker fixes reuse the existing service lifecycle.
- A watchdog operation keeps one owner through native activation, profile
  preparation, key rotation, preference persistence and cache acceptance.
  Session changes, explicit newer intent and location changes retire that owner.

Six overlapping files required source reconciliation. Existing signed key
confirmation, session-owned state, cancellation fences, cached-key revalidation
and one permission request per preparation remain in place. A key-admission
refusal reconciles preparation once. Uncertain issuance/rotation stops the
attempt without another mutation or failover; the later-cycle reconciliation
TODO remains in `connectionRecovery.ts`.

The reconciliation exposed an additional key-rotation boundary: checking an
operation only after its callback returns cannot prevent stale native-key or
cache writes inside that callback. The optional owner predicate now reaches
`rotateActiveProfile` and its existing API/key owner. Manual rotation without
an operation predicate retains its session fence. A regression fails on the
preceding callback and passes after this change.

## Build and dependency contract

The shared Android SDK installer is already present in both histories. Candidate
preparation captures its installer and package manifest from the orchestration
commit **before** selecting an older immutable source. Four inert local Git/SDK
fixtures cover current, qualified, native-routing and DNS-reliability sources,
including source/tree and SDK digest bindings. No signing or downloads run in
these fixtures; multiple-source rejection remains covered by workflow guards.

The qualified dependency maps and complete lock graph remain byte-equivalent to
the stability parent apart from the two root version fields. The incoming
`eoas@3.2.5` development entry is not restored: the retained OTA publisher
explicitly invokes `eoas@2.3.23`. That publisher is a positive usage, so this is
not a claim that EOAS is dead code. Existing dependency audit findings remain
open. Android metadata consistently identifies the imported private
1.0.82/build90/code1008290 candidate; no artifact is published by this merge.

## Numeric-port analysis follow-up

CodeQL on the initial combined commit reported an integer-conversion alert in
the imported adapter. Its existing parser already rejects values outside
0..65535. The conversion now immediately follows that check in the parsing
branch, and the common port variable has type uint16 with the existing zero
default for ping. Atoi's accepted signed-zero, positive-sign and leading-zero
forms remain compatible. Thirty-two literal-address/cancelled-context cases
pass against both the preceding and clarified implementation; they perform no
packet I/O. This is not a reproduced range-bypass vulnerability. Remote CodeQL
confirmation must come from the follow-up source, without suppressing the alert.

## Verification and limits

- Full `npm run check`: **1116 standard Node PASS events, one existing installed-
  Expo Swift-validator SKIP, zero FAIL**, plus **48 Python tests**, type checking,
  ESLint, upstream and portable CI/release contracts.
- Full Go1.26.10 routing suite with `-race -count=1`: **134 test PASS events**,
  zero test failures or skips. These are userspace/in-memory fixtures and do not
  change the active VPN, OS routes, DNS or PF. The initial merge had 101; the
  additional 33 events are the numeric-port parent test and its 32 cases. Vet passes.
- Focused recovery/key-owner suite: **88 PASS**; it overlaps the full check.
  The preceding callback fails the added stale-rotation control.
- Cached Kotlin2.1.20/JDK17 compilation of the exact two new pure Kotlin models
  and their JUnit4 suites: **six PASS**. This checks model behavior, not Android
  service/Gradle/JNI compilation or APK/device acceptance.

Windows work is deferred and the eleven parked Windows edits remain outside this
merge. Existing local worktree changes are preserved. Fresh current-head CI,
combined Android/JNI builds and representative device/network acceptance remain
separate evidence. Source review does not authorize signing, installation, OTA,
publication, or changes to a live VPN/network.

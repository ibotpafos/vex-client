# C36: separate root-private pre-stage consent (offline only)

The candidate is the existing release-readiness copy, not the running client. Original live source bytes, installed services, VPN, routes/DNS/PF and production are not changed.

## Executed root contract

`protected-authorize-stage` uses the original authenticated live kernel peer/start identity and UID, an existing 30-second one-use snapshot nonce, exact owner/source/candidate hashes, the canonical admitted staged config, source session and DNS policy. Root-private canonical `protected-pre-stage-consent.state` is 0600, bounded to 16 KiB, stores the capability hash (never its raw value or profile/key material), and has a non-extending 120-second window. Root health checks are fresh read-only ports. A separate pending-consent fence protects ordinary cleanup/watchdogs; this is deliberately NOT the existing owner-transfer fence that would block replacement.

The successful in-memory grant also pins the original consent capability digest and exact candidate. Missing/malformed/replaced consent cannot downgrade to legacy replacement. Before the first PF/quick/active-config port, the existing prepared journal durably stores and reads back optional `preStageConsentSHA256`; root rechecks that immutable consent, current canonical stage and original live owner. Journal presence and consumed snapshot fence replay. Future commit still needs the original root phase/fresh-handshake/route/DNS/IPv6 checks. The optional digest survives commit receipt persistence and the existing narrow owner-transfer normalization.

Original pre-stage consent can bridge into existing explicit restart recovery ONLY with the exact attached root journal or commit receipt. An orphaned record, expiry, metadata, dead PID, PID reuse, wrong UID/signature/capability or changed source/DNS/journal never writes ownership or proves admission/commit. Transfer ACK is still not a commit receipt. The same original live owner may explicitly cancel unconsumed/expired consent or exact restored-source custody; cancellation only removes its private record and never repeats physical recovery. Existing legacy RPC and nil-marker journal/receipt encoding are preserved; a completed prior consent cannot be reused by a fresh legacy tuple.

## Evidence and honest boundaries

The focused actual Swift root/runtime/store test currently passes 86 positive, negative, IO-boundary, real disposable private-file and compatibility cases, with inert physical ports. It checks journal/consent BEFORE the first fake PF mutation. Consent/journal after-rename/readback faults and identity changes are retained in command evidence; a prepared attached journal can transfer, whereas an orphaned record cannot. This is NOT actual OS crash/power-loss/fsync durability acceptance or current-console/signing/AF_UNIX validation on a separate Mac.

The same frozen evaluator will run on C35 BASELINE, MODIFIED and a separate ROLLBACK copy. Absence in BASELINE/ROLLBACK is explicitly reported as an absent contract, not execution of nonexistent runtime branches. Existing owner-transfer and client continuation fixtures, full offline aggregate, universal app/helper build, strict ad-hoc signatures, resources and ZIP roundtrip are gates recorded in the transaction ledger. Public release remains gated on Developer ID/notarization/provisioning and isolated install/connect/update/leak acceptance.

## First unfinished operation

The AppState/native cutover does NOT yet send these new stage RPCs. An adjacent `TODO(pre-stage-consent-client)` remains at NativeProtectedRestartCoordinator: wire current signed material/capability custody and the explicit client stage/cancel lifecycle before protected-replace, negotiate compatibility without silent legacy downgrade, and prove actual AppState boundaries using inert ports. Exact private post-promotion cleanup retry also remains. Do not claim the app crash gap or full Android parity/release is complete. No normal app/helper launch, VPN disconnect or production mutation is permitted in these checks.

## Retained aggregate timing failure

The first concurrent aggregate stopped at the unchanged AppState ordinary-push fixture (exit133, nested-push precondition) while the universal build was active. Fixed only the fixture wait: observe its exact two-fetch/one-completion/generation2/current-prepared result within a bounded two-second wait instead of counting Task.yield calls. The original postcondition remains unchanged; production AppState bytes are unchanged. Focused repeat, frozen B/M/R and a new full aggregate must pass; the failed transcript is retained.

A second aggregate (exit1) exposed the same counted-yield completion flaw in the unchanged active-normal-pending fixture (valid=false, other flags true). Its positive and obsolete/PSK job checks now observe exact bounded completion too; all original postconditions remain. No production AppState change. Fixture-only constant-condition diagnostic avoided without changing the presence check.

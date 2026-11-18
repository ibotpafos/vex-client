# Compatible dependency patches and realtime timer types

25 October 2026. Source baseline: `e5000b3b18f5348d20fa6c6f809a3c35de1512df`.

The client keeps Expo SDK 57, its native dependencies, application version,
authentication, key/profile handling, network policy and release/signing gates.
Five existing lock entries change; no package path is added or removed:

| Package | Before | After |
| --- | --- | --- |
| body-parser | 2.3.0 | 2.4.0 |
| qs, required by body-parser | 6.16.0 | 6.16.1 |
| fast-uri | 3.1.8 | 3.1.9 |
| undici | 6.29.0 | 6.29.1 |
| external Zod 4 | 4.6.5 | 4.6.7 |

The complete include-dev npm audit changes from **11 package findings
(10 high, one moderate) to eight high findings**. These counts include affected
parent chains, not eleven independent vulnerabilities. The audit still fails;
no advisory is suppressed and no clean-client or deployment claim is made.

## Retained dependency limits

Expo CLI, expo-mcp and its tunnel still require Zod 3. Even the checked compatible
CLI 57.0.32 retains `^3.25.76`. The package-level
[Zod advisory](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5) lists a fix in
4.6.6, so a Zod 4 override cannot be assumed compatible with these owners.
The SDK also imports `zod/v3` from the 4.x package. A patched external package
version does not attest every legacy implementation inside it.

Published expo-mcp/tunnel 0.3.1 is a maintained migration candidate under the
`next` tag; `latest` remains 0.2.4. Its CLI-facing exports, transport and handshake
remain compatible in the inspected source. However, the current CLI creates
Zod 3 schemas for MCP-enabled DevTools extensions. The new tunnel feeds them
directly into the Zod 4 JSON-schema converter. An isolated synthetic extension
using the actual CLI registration function succeeds with tunnel 0.2.4 and fails
with 0.3.1 (`TypeError`, reading `def`). No socket or command is started by that
fixture. This establishes a conditional upgrade incompatibility, not an active
VEX incident. The current pair is retained until a maintained producer path can
handle those schemas. The adjacent `stability-zod3-producers` code TODO preserves
this remaining work, while npm audit continues to report the affected packages.

The checked latest node-forge is 1.4.0. Its
[signature-verification advisory](https://github.com/advisories/GHSA-86w9-cpqp-85rv)
lists no patched release. Expo certificate/publisher qualification remains open;
the existing publisher TODO and signing/OTA compatibility policy are preserved.
The audit's suggested Expo 54 downgrade is not applied to this SDK 57 project.

## Timer contract

Full qualification exposed two TypeScript errors: the default scheduler can
return a numeric handle while fields admitted only a Node `Timeout`. One shared
timer type now admits numeric and object handles in scheduling, cancellation and
both owned timer fields. Three numeric test schedulers no longer cast their
handles through `unknown`.

Realtime JavaScript emitted from the parent and current source is byte-equal
with comments removed. No scheduling, generation fence, stream lifecycle,
deadline, retry or cancellation statement changes. A new runtime case verifies
that an actual Node timer object returns to the matching cancellation hook and
the stream reader is released; existing numeric-clock cases remain covered.
The dependency update is not established as the cause of the earlier type error.

## Verification

- Full `npm run check` passes: unit and upstream contracts, TypeScript, ESLint,
  CI/release-script contracts and their Python fixtures. `npm run contract:check`
  also passes. Standard Node summaries report **989 PASS, one existing SKIP,
  zero failures**; Python fixtures run **48 tests**. The skipped installed Expo
  Swift validator requires the selected compiler in macOS CI. These are local
  source checks, not platform/device acceptance.
- The dependency suite has **13 passing test events**. It exercises actual
  Express/body-parser and an owned Undici pool over loopback for JSON, gzip,
  forms, malformed and oversized bodies, abort and cleanup. The SDK's actual
  Ajv 8 owner resolves relative `$ref` through the installed fast-uri. In-memory
  MCP negotiation validates Zod 4 and legacy schemas without device/provider
  operations.
- **56 realtime test events pass**, including the new Node-handle case. These
  events and the dependency cases are included in the full check, not additional
  independent acceptance totals.
- The exact preceding lock fails the new patched-line checks for body-parser,
  fast-uri, undici and external Zod 4. This is a lock-policy negative control,
  not a test of every preceding installed runtime.

The first URI fixture loaded ESLint's Ajv 6, which uses a different URI library.
It now selects the SDK-owned Ajv 8 and asserts its fast-uri resolution. The first
candidate-reproduction launcher mishandled spaces in its file URL; the corrected
launcher uses `fileURLToPath`. Failed receipts are retained. Neither correction
weakens the dependency or compatibility requirements.

An initial lock experiment admitted fourteen peer package paths. It was rejected
before source changes. Repeating in a new private experiment with the project's
existing peer-resolution policy produces only the five reviewed entries above.
All installation scripts were disabled, and build/cache/fixture outputs stayed
on the development volume. No SDK migration, vendor patch, actual tunnel,
release, signing, OTA publication or production operation accompanies this patch.

Remaining work includes the retained dependency producer paths, broader profile
and recovery outcomes, orphan/base-counter cases, later watchdog cycles and
representative current platform, device and workload qualification.

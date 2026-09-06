# VEX Dynamic Server Catalog Design

**Date:** 2026-09-06
**Status:** Approved for implementation planning
**Owners:** VEX API and native client
**Tracking:** IBO-119 dynamic-catalog workstream, related to IBO-284. A dedicated issue could not be created because the Linear workspace reached its issue limit.

## Goal

Make the VEX native application consume a server-managed VPN location catalog so that adding, changing, reordering, disabling, or removing a server does not require an Android or iOS release. Production clients must not invent FI, DE, NL, or any other location locally.

The first acceptance target is the production Android client: a newly available NL AWG 3.1 location must appear, remain reachable in the picker, and establish a working tunnel without an APK change after the compatible client version is installed.

## Current State and Problem

The API already builds `GET /v1/locations` from the `locations`, VPN-node, capacity, and metrics records. The client also requests this endpoint and stores the result in a per-user cache. However, server management is not yet fully dynamic at the application boundary:

- the client contains built-in DE and FI fallback fixtures;
- the selected location starts as the hard-coded value `de` before persisted preferences load;
- presentation names are partly translated through a client-side country map;
- the client ignores the API `priority` field and has no explicit capability metadata;
- refresh is interval-based and does not guarantee a fresh request when the app returns to the foreground or when the picker opens;
- the Android picker renders an unbounded `Column` inside a bottom sheet, so locations below the visible area cannot reliably be reached.

The result is operationally misleading: the backend can contain a valid new server while a user sees an old cached catalog or cannot scroll to the new entry.

## Non-goals

- Moving private tunnel configuration, keys, or AWG obfuscation secrets into the location catalog.
- Replacing the existing managed-profile issuance endpoint.
- Changing customer entitlement rules or making unavailable locations selectable.
- Adding a second catalog in a CDN, mobile bundle, or remote-config document.
- Automatically migrating an active user to a newly added server without the existing auto-selection and recovery rules.

## Chosen Architecture

`GET /v1/locations` is the single production source of truth. The API remains backed by the existing database and node-health model. The native client keeps only a validated last-known-good cache for offline continuity.

The flow is:

1. Operations create or update a location and associate healthy nodes through the existing server-side management path.
2. The API derives a client-safe catalog entry from location metadata plus live node availability.
3. The client fetches and validates the full catalog as one atomic snapshot.
4. A valid non-empty snapshot replaces the in-memory catalog and last-known-good per-user cache.
5. UI selection, auto-selection, latency probes, profile requests, and failover operate only on that snapshot.
6. Private profile material continues to arrive only from the authenticated profile endpoint after a location is selected.

No production execution path falls back to locally declared locations.

## API Contract

The existing response remains a JSON array for backward compatibility. Each entry exposes only client-safe metadata:

```json
{
  "id": "nl-awg3",
  "country_code": "NL",
  "city": "Amsterdam",
  "display_name": "Нидерланды",
  "flag_emoji": "🇳🇱",
  "availability": "available",
  "priority": 30,
  "status": "healthy",
  "healthy_nodes": 1,
  "endpoint": "79.137.197.215:51821",
  "latency_ms": 42,
  "capabilities": ["awg31"]
}
```

### Field rules

- `id` is the stable opaque selector passed back to the profile endpoint. Clients must not derive geography or protocol from it.
- `display_name` is the server-controlled user-facing label. Older API responses without it remain supported by falling back to `city`, not to a local location table.
- `country_code` and `flag_emoji` are presentation metadata and do not control routing.
- `priority` is the stable server-managed order; ties are resolved by `id`.
- `availability` and `healthy_nodes` determine selectability. Retired or zero-healthy-node entries are excluded from the selectable client snapshot.
- `capabilities` is additive and contains public engine families such as `awg30` and `awg31`. Unknown values are ignored by older clients. Tunnel parameters and keys are never included.
- `endpoint` is optional client-safe probe metadata. Profile issuance remains authoritative for the actual tunnel endpoint.
- `latency_ms` is optional server telemetry; a current device-side measurement may replace it in memory.

The endpoint returns all catalog entries visible to the current client policy in a deterministic order. A total backend failure returns a non-2xx response. An empty successful response is valid only when the account truly has no selectable locations; it must not be replaced with bundle fixtures.

The API contract is extended additively. Existing clients that ignore new fields continue to work.

## Client Catalog Model

Introduce a normalized catalog boundary that owns parsing, validation, sorting, and snapshot replacement. UI and VPN flows consume `VpnLocation[]` from this boundary and never import fixtures.

Validation requirements:

- reject entries without a non-empty `id`, `country_code`, `city`, `availability`, and numeric `healthy_nodes`;
- normalize IDs for comparison without rewriting the opaque value sent to the API;
- ignore retired and zero-healthy-node entries for selection;
- sort by `priority`, then stable `id`;
- ignore unknown additive fields and unknown capability strings;
- reject a malformed response as a whole instead of partially replacing a good cache with ambiguous data;
- deduplicate IDs deterministically and report the contract violation through existing diagnostics.

Development and tests may create fixtures inside test utilities. Application production modules contain no concrete location IDs or endpoints.

## Cache and Refresh Policy

The per-user secure cache remains last-known-good rather than a second source of truth.

### Read order

1. Render a still-valid cached snapshot immediately when available.
2. Start a network refresh without waiting for the cache to expire.
3. Atomically replace cache and UI only after full response validation.

### Refresh triggers

- authenticated application startup;
- transition from background or inactive to foreground;
- opening the server picker;
- successful session refresh;
- periodic refresh while authenticated and active;
- explicit retry after a catalog error.

Concurrent triggers are coalesced into one in-flight request. A slower older request cannot overwrite a newer snapshot.

### Failure behavior

- Network/server error with a valid cache: keep the cache, expose a non-blocking stale indicator, and retry later.
- Malformed response with a valid cache: keep the cache, record a contract diagnostic, and do not persist the malformed data.
- No API result and no valid cache: show an empty state and disable new connections with a clear retry action.
- Existing active tunnel during catalog failure: do not tear it down solely because refresh failed.
- A successful authoritative snapshot that no longer contains the manually selected location: switch the stored selection to auto; do not silently retain an orphaned ID for the next connection.

Cache entries remain scoped by user ID and schema version. Sign-out, definitive entitlement revocation, and account changes clear the relevant snapshot.

## Selection and Connection Behavior

Initial selection mode is `auto`. There is no hard-coded initial country.

When the catalog becomes available:

- restore a persisted manual selection only if its ID is still selectable;
- otherwise remain in auto mode and choose the best candidate through the existing health and device-latency ranking;
- pass the chosen opaque ID to managed-profile issuance;
- use capability metadata only for compatibility gating, never to synthesize a profile;
- preserve the existing rollback behavior when switching an active tunnel fails.

Removing or retiring a location affects new connections immediately after refresh. It does not destroy an active tunnel; watchdog recovery resolves a fresh selectable target if reconnection becomes necessary.

## User Interface

The location carousel continues to show a small selection of candidates. “All locations” opens a scalable picker backed by the current catalog snapshot.

On Android, replace the unbounded Compose `Column` used for location rows with a vertically scrollable lazy list or navigate to the existing full-screen picker route when the bottom sheet cannot provide reliable lazy scrolling. The selected row, automatic option, accessibility descriptions, and stable `testID` values remain available.

The picker must support at least 20 locations on the Mi A1 Android 9 acceptance device. A newly added NL entry must be reachable without screen-size assumptions. Loading, stale-cache, empty, and retry states are explicit.

User-facing labels use `display_name` when supplied and `city` otherwise. The client may localize generic UI words such as “Available” and “Automatically,” but it does not maintain a map of server or country names.

## Observability

Use the existing diagnostics channel with bounded metadata only:

- catalog refresh outcome and duration;
- source rendered: network, fresh cache, or stale cache;
- entry count and snapshot version/hash;
- validation failure category without raw response bodies;
- selected location ID and selection mode;
- picker opened and requested refresh outcome.

Do not log access tokens, private keys, profile bodies, or complete endpoint inventories.

## Test Strategy

### API

- database-created location appears without source changes;
- priority and additive metadata are serialized correctly;
- retired and unhealthy state is represented consistently;
- deterministic ordering is preserved;
- existing response consumers remain compatible.

### Client unit and integration

- arbitrary location IDs are parsed and sorted without a built-in allowlist;
- a new NL entry appears from a synthetic API response;
- malformed or duplicate snapshots do not overwrite last-known-good cache;
- startup, foreground, picker-open, and session-refresh triggers request refresh;
- concurrent and out-of-order refreshes cannot regress the snapshot;
- a removed manual selection returns to auto;
- no-cache failure disables connection and provides retry;
- stale-cache failure preserves browsing and an existing tunnel;
- production modules contain no concrete DE/FI/NL location fallback entries or default location ID;
- the Android picker can reach and select the twentieth item.

Tests follow red-green-refactor. Each behavior is first captured by a failing test before production code changes.

### Physical Android acceptance

1. Install a signed candidate over a supported prior production build without clearing account data.
2. Start with NL absent, then make NL available server-side without rebuilding the APK.
3. Foreground the app or open the picker and verify NL appears.
4. Select NL and connect.
5. Verify Android reports an active VPN network and tunnel interface.
6. Verify DNS, HTTPS, packet loss, external IP `79.137.197.215`, and server-side fresh handshake/counter growth.
7. Disconnect and reconnect once.
8. Retire NL server-side, refresh, and verify it is no longer selectable while an already active tunnel is not forcibly terminated by catalog refresh alone.
9. Inspect application crash buffer, bounded diagnostics, and NL service logs.

## Rollout and Rollback

1. Release additive API fields first; old clients ignore them.
2. Verify production catalog contains FI, DE, feature locations, and NL in deterministic order.
3. Build and test the client candidate locally and on the physical Android device.
4. Publish through the normal signed staged client channel; do not claim production acceptance from a local APK.
5. Observe catalog refresh errors, empty states, connection success, and crash-free sessions before broad rollout.

Client rollback is the previous signed build. API rollback removes only additive fields while preserving the current base response. Because the new client falls back from `display_name` to `city` and ignores absent capabilities, it remains functional during API rollback. Server catalog changes remain independently reversible through the existing location-management path.

## Acceptance Criteria

- Adding a compatible healthy server through the backend makes it visible to an installed compatible VEX client without changing client source or releasing another APK.
- Removing or retiring it removes it from new selection after refresh.
- Production client code contains no concrete location fallback catalog and no hard-coded default location ID.
- Last-known-good cache provides bounded offline continuity without masking authoritative deletions after a successful refresh.
- Android users can scroll to and select every returned location on the physical acceptance device.
- NL AWG 3.1 completes connect, traffic, disconnect, and reconnect checks with the expected public IP.
- API, client unit/type/lint checks, signed build verification, physical E2E, and staged rollout evidence are recorded separately.

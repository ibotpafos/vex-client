# VEX Dynamic Server Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the VEX native app render, refresh, select, and connect to an API-managed VPN server catalog without built-in location IDs, endpoint templates, or an APK release for each server change.

**Architecture:** Extend the existing database-backed `GET /v1/locations` contract additively, then normalize every response into one validated client snapshot. The client renders a per-user last-known-good snapshot while revalidating on lifecycle and picker events, selects only IDs present in that snapshot, and uses an Android `LazyColumn` so every returned server is reachable.

**Tech Stack:** Go 1.25 API, PostgreSQL/SQLite-compatible sqlstore migrations, TypeScript 6, React 19, React Native 0.86, Expo 57, TanStack Query 5, `@expo/ui` Jetpack Compose, adb physical-device QA.

**Spec:** `docs/superpowers/specs/2026-09-06-dynamic-server-catalog-design.md`

## Global Constraints

- `GET /v1/locations` is the only production catalog source; no client fixture may invent FI, DE, NL, or an endpoint.
- Tunnel keys, profile bodies, and AWG obfuscation parameters stay out of the catalog.
- API changes are additive and remain compatible with clients that ignore `display_name` and `capabilities`.
- A failed or malformed refresh never overwrites the last-known-good cache and never tears down an active tunnel by itself.
- Initial selection mode is `auto`; a concrete location is selected only from the current validated snapshot.
- The Android picker must reach at least 20 entries on the Mi A1 Android 9 acceptance device.
- Do not modify the dirty primary checkout at `/Volumes/D/Projects/mobile/vex-client`; implementation stays in `/Volumes/D/Projects/mobile/vex-client/.worktrees/dynamic-server-catalog`.
- The implementation branch is based on committed client revision `24afbb7`; before integration, reconcile overlapping uncommitted primary-checkout edits without overwriting them.
- Implement API work in a separate `/Volumes/D/Projects/vpn-main/.worktrees/dynamic-server-catalog-api` worktree based on the accepted PR #350 floor `d5e5aeaa0` or its integrated successor.
- Follow red-green-refactor for every production behavior.
- Keep the installed Expo dependency unchanged. The picker implementation uses the documented `@expo/ui/jetpack-compose` `LazyColumn`.

---

### Task 1: Add client-safe catalog metadata to the API

**Repository:** `/Volumes/D/Projects/vpn-main`

**Files:**
- Create: `internal/store/sqlstore/location_catalog_migration.go`
- Create: `internal/store/sqlstore/location_catalog_migration_test.go`
- Modify: `internal/store/sqlstore/migration_steps.go:25-52`
- Modify: `internal/store/sqlstore/migration_schema.go:473-482`
- Modify: `internal/store/sqlstore/locations.go:11-56`
- Modify: `internal/store/sqlstore/scan.go:99-110`
- Modify: `internal/domain/node_types.go:82-123`
- Modify: `internal/app/service_locations.go:322-340`
- Modify: `internal/api/admin_node_handlers.go:73-79,220-228`
- Modify: `internal/api/dto/types_node.go:123-149,185-201`
- Test: `internal/app/service_locations_test.go`
- Test: `internal/api/server_test.go`

**Interfaces:**
- Consumes: existing `LocationsService.ListLocationsCompact(ctx) ([]domain.LocationStatus, error)` and priority ordering.
- Produces: `display_name: string` and `capabilities: string[]` on `GET /v1/locations`; matching `domain.Location` and `domain.LocationUpsert` fields.

- [ ] **Step 1: Create the isolated backend worktree**

```bash
cd /Volumes/D/Projects/vpn-main
git check-ignore -q .worktrees
git worktree add .worktrees/dynamic-server-catalog-api -b codex/dynamic-server-catalog-api d5e5aeaa0
```

Expected: clean worktree at the accepted NL stability floor. If that commit was superseded, resolve and record the integrated successor first.

- [ ] **Step 2: Write failing migration and storage tests**

```go
func TestLocationCatalogMetadataRoundTrip(t *testing.T) {
    dsn := os.Getenv("TEST_DATABASE_URL")
    if dsn == "" { t.Skip("TEST_DATABASE_URL is not set") }
    db, err := OpenPostgres("pgx", dsn, secrets.NoopProvider{})
    if err != nil { t.Fatal(err) }
    defer db.Close()
    got, err := db.UpsertLocation(context.Background(), domain.LocationUpsert{
        ID: "edge-next",
        CountryCode: "ZZ",
        City: "Edge City",
        DisplayName: "Fast Edge",
        FlagEmoji: "🌐",
        Availability: "available",
        Priority: 7,
        Capabilities: []string{"awg31"},
    })
    if err != nil { t.Fatal(err) }
    if got.DisplayName != "Fast Edge" || !slices.Equal(got.Capabilities, []string{"awg31"}) {
        t.Fatalf("unexpected catalog metadata: %+v", got)
    }
}
```

Also create a legacy database without the new columns, run migrations, and assert safe defaults `display_name=''` and `capabilities_json='[]'`.

- [ ] **Step 3: Run the focused tests and verify RED**

```bash
go test ./internal/store/sqlstore -run 'TestLocationCatalogMetadata' -count=1
```

Expected: FAIL because the fields and migration do not exist.

- [ ] **Step 4: Implement the idempotent schema/storage change**

Add `display_name TEXT NOT NULL DEFAULT ''` and `capabilities_json TEXT NOT NULL DEFAULT '[]'` to the canonical schema and this migration:

```go
func (s *Store) applyPostSchemaLocationCatalog(ctx context.Context) error {
    for _, column := range []struct{ name, definition string }{
        {"display_name", "TEXT NOT NULL DEFAULT ''"},
        {"capabilities_json", "TEXT NOT NULL DEFAULT '[]'"},
    } {
        if err := s.addColumnIfMissing(ctx, "locations", column.name, column.definition); err != nil {
            return err
        }
    }
    return nil
}
```

Register the migration step. Update every location SELECT, INSERT, upsert, and scan together. Encode normalized capabilities as JSON and decode invalid legacy values as an empty slice.

- [ ] **Step 5: Verify storage GREEN**

```bash
go test ./internal/store/sqlstore -run 'TestLocationCatalogMetadata' -count=1
```

Expected: PASS.

- [ ] **Step 6: Write failing service and HTTP contract tests**

```go
func TestNormalizeLocationUpsertDefaultsDisplayNameAndCapabilities(t *testing.T) {
    got, err := normalizeLocationUpsert(domain.LocationUpsert{
        ID: "edge-next", CountryCode: "zz", City: "Edge City",
        Availability: "available", Capabilities: []string{" AWG31 ", "awg31", ""},
    })
    if err != nil { t.Fatal(err) }
    if got.DisplayName != "Edge City" { t.Fatalf("display name = %q", got.DisplayName) }
    if !slices.Equal(got.Capabilities, []string{"awg31"}) {
        t.Fatalf("capabilities = %#v", got.Capabilities)
    }
}
```

Extend the HTTP test to decode `display_name`, `priority`, and `capabilities`, and assert arbitrary entries are ordered by priority.

- [ ] **Step 7: Run the service/API tests and verify RED**

```bash
go test ./internal/app ./internal/api -run 'TestNormalizeLocationUpsertDefaultsDisplayNameAndCapabilities|TestListLocations' -count=1
```

Expected: FAIL because normalization and DTO mapping omit the fields.

- [ ] **Step 8: Implement normalization, admin input, and DTO mapping**

```go
type LocationStatusDTO struct {
    ID           string   `json:"id"`
    CountryCode  string   `json:"country_code"`
    City         string   `json:"city"`
    DisplayName  string   `json:"display_name"`
    FlagEmoji    string   `json:"flag_emoji,omitempty"`
    Availability string   `json:"availability"`
    Priority     int      `json:"priority"`
    Capabilities []string `json:"capabilities"`
    // Existing health and capacity fields remain unchanged.
}
```

Default absent display name to `City`. Normalize capabilities by trim, lowercase, empty removal, deduplication, and lexical sort. Never infer `awg31` from an ID substring.

- [ ] **Step 9: Verify and commit the backend slice**

```bash
go test ./internal/store/sqlstore ./internal/app ./internal/api -count=1
go vet ./internal/...
git diff --check
git add internal/store/sqlstore internal/domain/node_types.go internal/app/service_locations.go internal/app/service_locations_test.go internal/api/admin_node_handlers.go internal/api/dto/types_node.go internal/api/server_test.go
git commit -m "feat(api): expose managed VPN location catalog metadata"
```

Expected: all checks exit 0 before the commit.

---

### Task 2: Normalize an arbitrary server catalog in the client

**Repository:** `/Volumes/D/Projects/mobile/vex-client/.worktrees/dynamic-server-catalog`

**Files:**
- Create: `src/vpn/locationCatalog.ts`
- Modify: `src/api/dto.ts:78-88`
- Modify: `src/api/types.ts:101-111`
- Modify: `src/api/vpn.ts:177-179,447-458`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: additive API `LocationDTO` entries.
- Produces: `normalizeLocationCatalog(items: LocationDTO[]): VpnLocation[]`, `VpnLocationCatalogError`, `VpnLocation.displayName`, `priority`, `capabilities`, and the reusable test value `catalogFixture`.

- [ ] **Step 1: Write failing normalization tests**

```ts
const catalogFixture: VpnLocation = {
  id: 'edge-a',
  countryCode: 'XY',
  city: 'First',
  displayName: 'First Edge',
  availability: 'available',
  priority: 10,
  status: 'healthy',
  healthyNodes: 1,
  capabilities: ['awg31'],
};

assertDeepEqual(
  normalizeLocationCatalog([
    { id: 'edge-b', country_code: 'ZZ', city: 'Second', priority: 20, availability: 'available', status: 'healthy', healthy_nodes: 1 },
    { id: 'edge-a', country_code: 'XY', city: 'First', display_name: 'First Edge', priority: 10, capabilities: ['awg31'], availability: 'available', status: 'healthy', healthy_nodes: 1 },
  ]).map((location) => [location.id, location.displayName]),
  [['edge-a', 'First Edge'], ['edge-b', 'Second']],
);

assertThrows(
  () => normalizeLocationCatalog([
    { id: 'duplicate', country_code: 'ZZ', city: 'One', healthy_nodes: 1 },
    { id: 'DUPLICATE', country_code: 'ZZ', city: 'Two', healthy_nodes: 1 },
  ]),
  'duplicate location id',
);
```

Add malformed required-field and retired/zero-healthy filtering cases.

- [ ] **Step 2: Run unit tests and verify RED**

```bash
npm run test:unit
```

Expected: FAIL because `locationCatalog.ts` does not exist.

- [ ] **Step 3: Add contract fields and the normalizer**

```ts
export type VpnLocation = {
  id: string;
  countryCode: string;
  city: string;
  displayName: string;
  flagEmoji?: string;
  availability: string;
  priority: number;
  status: string;
  healthyNodes: number;
  capabilities: string[];
  endpoint?: string;
  latencyMs?: number;
};
```

Validate the full input before returning. Filter unavailable entries, sort by `priority` then `id`, preserve the API ID as opaque, reject duplicate IDs case-insensitively, and fall back from `display_name` only to server-provided `city`.

- [ ] **Step 4: Route the API through the normalizer**

```ts
export async function vpnLocations(accessToken: string): Promise<VpnLocation[]> {
  const response = await jsonRequest<LocationDTO[]>('/v1/locations', {
    accessToken,
    suppressErrorLog: true,
  });
  return normalizeLocationCatalog(response);
}
```

Do not substitute `item.id.toUpperCase()` for missing required metadata.

- [ ] **Step 5: Verify GREEN and commit**

```bash
npm run test:unit
npm run typecheck
git diff --check
git add src/api/dto.ts src/api/types.ts src/api/vpn.ts src/vpn/locationCatalog.ts tests/run-unit-tests.ts
git commit -m "feat(vpn): normalize server-managed location catalog"
```

Expected: all checks exit 0.

---

### Task 3: Remove production location and endpoint fallbacks

**Files:**
- Modify: `src/screens/home-screen-helpers.ts:130-148,169-190`
- Modify: `src/settings/vpnPreferences.ts:11-121`
- Modify: `src/vpn/useVpnConnection.ts:160-270,550-575,680-700`
- Delete: `src/vpn/locationEndpoint.ts`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: validated `VpnLocation[]` from Task 2.
- Produces: no-fallback `availableVpnLocations`; nullable stored location; `reconcileLocationSelection(mode, selectedId, locations)`.

- [ ] **Step 1: Write failing no-fallback and selection tests**

```ts
assertDeepEqual(availableVpnLocations(undefined, false), []);
assertDeepEqual(availableVpnLocations([], false), []);
assertEqual(serverLocationLabel({ ...catalogFixture, displayName: 'Managed Name' }), 'Managed Name');

assertDeepEqual(
  reconcileLocationSelection('manual', 'removed-id', [catalogFixture]),
  { mode: 'auto', selectedLocationId: catalogFixture.id },
);
assertDeepEqual(
  reconcileLocationSelection('auto', null, [catalogFixture]),
  { mode: 'auto', selectedLocationId: catalogFixture.id },
);
```

Update storage tests so an absent location returns `null` and empty input is rejected instead of becoming `de`.

- [ ] **Step 2: Run unit tests and verify RED**

```bash
npm run test:unit
```

Expected: FAIL on current fixtures, local country map, default `de`, and endpoint template.

- [ ] **Step 3: Remove concrete fallbacks**

Delete `fallbackVpnLocations`, `russianCountryNames`, and `fallbackLocationEndpoint`. Make `serverLocationLabel` return `displayName || city`. Make `getSelectedVpnLocation()` return `Promise<string | null>`, reject empty IDs in `setSelectedVpnLocation`, initialize selection to `''`, and probe latency only when the API supplies `location.endpoint`.

```ts
export function reconcileLocationSelection(
  mode: ServerSelectionMode,
  selectedLocationId: string | null,
  locations: VpnLocation[],
): { mode: ServerSelectionMode; selectedLocationId: string } {
  const selected = selectedLocationId
    ? locations.find((item) => item.id.toLowerCase() === selectedLocationId.toLowerCase())
    : undefined;
  if (mode === 'manual' && selected) return { mode, selectedLocationId: selected.id };
  return { mode: 'auto', selectedLocationId: chooseBestVpnLocation(locations)?.id ?? '' };
}
```

- [ ] **Step 4: Add a hardcode regression check**

Read only executable source modules from `tests/run-unit-tests.ts` and fail if they contain `fallbackVpnLocations`, `defaultVpnLocation`, `russianCountryNames`, `fallbackLocationEndpoint`, or `de-1.vexguard.app`. Exclude tests, docs, and profile examples.

- [ ] **Step 5: Verify GREEN and commit**

```bash
npm run test:unit
npm run typecheck
rg -n "fallbackVpnLocations|defaultVpnLocation|russianCountryNames|fallbackLocationEndpoint|de-1\\.vexguard\\.app" src
git diff --check
git add src/screens src/settings/vpnPreferences.ts src/vpn/useVpnConnection.ts src/vpn/serverSelection.ts src/vpn/locationEndpoint.ts tests/run-unit-tests.ts
git commit -m "refactor(vpn): remove bundled server fallbacks"
```

Expected: tests/typecheck pass and the search returns no executable-source matches.

---

### Task 4: Add last-known-good refresh orchestration

**Files:**
- Create: `src/vpn/locationCatalogRefresh.ts`
- Modify: `src/vpn/vpnQueryCache.ts`
- Modify: `src/vpn/useVpnConnection.ts:230-480,745-766,1244-1255`
- Modify: `src/vpn/useVpnDiagnostics.ts`
- Modify: `src/vpn/vpn-connection-context.tsx`
- Modify: `src/screens/server-picker-screen.tsx`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: `fetchCatalog(): Promise<VpnLocation[]>`, per-user cache, `AppState`, and picker-open action.
- Produces: `createLocationCatalogRefresher(options).refresh(reason)` and UI catalog state.

- [ ] **Step 1: Write failing coalescing and last-known-good tests**

```ts
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

const pending = deferred<VpnLocation[]>();
let calls = 0;
const refresher = createLocationCatalogRefresher({
  fetchCatalog: () => { calls += 1; return pending.promise; },
  commitCatalog: async () => undefined,
});
const first = refresher.refresh('startup');
const second = refresher.refresh('picker_open');
assertEqual(calls, 1);
pending.resolve([catalogFixture]);
assertDeepEqual(await first, await second);
```

Add cases for request failure preserving the prior snapshot, authoritative empty snapshots, and a later refresh replacing an older snapshot.

- [ ] **Step 2: Run unit tests and verify RED**

```bash
npm run test:unit
```

Expected: FAIL because the refresher does not exist.

- [ ] **Step 3: Implement the single-flight refresher**

```ts
export type LocationCatalogRefreshReason =
  | 'startup' | 'foreground' | 'picker_open' | 'session_refresh' | 'interval' | 'retry';

export type LocationCatalogRefreshResult = {
  locations: VpnLocation[];
  source: 'network';
  reason: LocationCatalogRefreshReason;
};
```

Return the same in-flight promise to concurrent callers. Commit only validated snapshots. Let failures propagate to the hook so it retains `persistedLocations` and exposes stale/error state.

Increment the location-cache schema version when the stored `VpnLocation` shape gains `displayName`, `priority`, and `capabilities`. Keep cache entries scoped by normalized user ID; add tests proving one user's catalog is never returned for another user and the previous schema is discarded.

- [ ] **Step 4: Wire lifecycle and picker triggers**

Use one stable `refreshLocations(reason)` callback with `staleTime: 0` for explicit revalidation. Trigger on authenticated startup, foreground, picker open, successful session refresh, retry, and the existing interval.

```ts
const openServerPicker = useCallback((visibleLatencyText?: string, visibleLocationId?: string) => {
  void refreshLocations('picker_open');
  playSelectionHaptic();
  router.push({
    pathname: SERVER_PICKER_ROUTE,
    params: {
      activeLatencyText: visibleLatencyText || '',
      activeLocationId: visibleLocationId || '',
    },
  });
}, [refreshLocations]);
```

- [ ] **Step 5: Expose empty, stale, and retry state**

A refresh error keeps cached locations. A successful empty snapshot clears selectable locations. Disable new connection only when there is no selected validated location and no existing active or leak-blocked tunnel. Add a retry callback to the connection context and picker empty state.

Report bounded diagnostics for refresh reason, outcome, duration, source (`network`, `fresh_cache`, or `stale_cache`), entry count, and validation failure category. Never include access tokens, raw response bodies, keys, profiles, or complete endpoint inventories. Add unit assertions for the sanitized diagnostics payload.

- [ ] **Step 6: Verify GREEN and commit**

```bash
npm run test:unit
npm run typecheck
npm run lint
git diff --check
git add src/vpn/locationCatalogRefresh.ts src/vpn/vpnQueryCache.ts src/vpn/useVpnConnection.ts src/vpn/useVpnDiagnostics.ts src/vpn/vpn-connection-context.tsx src/screens/server-picker-screen.tsx tests/run-unit-tests.ts
git commit -m "feat(vpn): refresh managed server catalog across app lifecycle"
```

Expected: all checks exit 0 with no new warnings.

---

### Task 5: Make the Android picker scalable and accessible

**Files:**
- Modify: `src/components/server-picker-modal.tsx:1-210`
- Modify: `src/screens/server-picker-screen.tsx`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: catalog state and retry callback from Task 4.
- Produces: Android `LazyColumn` rows with stable `server-picker-${location.id}` semantics.

- [ ] **Step 1: Write a failing structural regression test**

```ts
const repoRoot = process.cwd();
const pickerSource = readFileSync(
  resolve(repoRoot, 'src/components/server-picker-modal.tsx'),
  'utf8',
);
assertEqual(pickerSource.includes('LazyColumn'), true);
assertEqual(pickerSource.includes('<LazyColumn'), true);
```

Also keep behavior checks for stable row IDs, auto selection, empty state, and retry callback.

- [ ] **Step 2: Run unit tests and verify RED**

```bash
npm run test:unit
```

Expected: FAIL because all server rows are inside a non-scrollable Compose `Column`.

- [ ] **Step 3: Use Expo Jetpack Compose LazyColumn**

```tsx
import {
  LazyColumn,
  ListItem as ComposeListItem,
  ModalBottomSheet,
  Text as ComposeText,
} from '@expo/ui/jetpack-compose';

<LazyColumn contentPadding={{ bottom: 24 }}>
  <ServerPickerRow
    leading="↻"
    onPress={isVpnBusy ? undefined : onAutoSelect}
    supportingText="Лучший доступный сервер"
    testID="server-picker-auto"
    trailing={selectionMode === 'auto' ? '✓' : undefined}
  >
    Автоматически
  </ServerPickerRow>
  {locations.map((location) => (
    <ServerPickerRow
      key={location.id}
      leading={location.flagEmoji || location.countryCode}
      onPress={isVpnBusy ? undefined : () => onSelect(location.id)}
      supportingText={`${locationStatusText(location)} · ${locationLatencyText(location)}`}
      testID={`server-picker-${location.id}`}
      trailing={selectionMode === 'manual' && location.id === selectedLocationId ? '✓' : undefined}
    >
      {serverLocationLabel(location)}
    </ServerPickerRow>
  ))}
</LazyColumn>
```

Give the host/sheet content an explicit bounded height. Do not use `matchContents` on the vertical scroll axis.

- [ ] **Step 4: Verify compile and a 20-item adb fixture**

```bash
npm run test:unit
npm run typecheck
npm run lint
npm run android:build:debug:fast
```

Install the debug candidate against a development catalog with 20 entries. Use UIAutomator-tree-derived coordinates, scroll to `server-picker-edge-20`, select it, and confirm an empty crash buffer.

- [ ] **Step 5: Commit the picker slice**

```bash
git add src/components/server-picker-modal.tsx src/screens/server-picker-screen.tsx tests/run-unit-tests.ts
git commit -m "fix(android): make dynamic server picker scrollable"
```

---

### Task 6: Cross-repository verification and integration review

**Files:**
- Modify: `src/api/generated-contract.ts`
- Update: Linear IBO-119 evidence comments

**Interfaces:**
- Consumes: backend and client commits from Tasks 1-5.
- Produces: review-ready branches with reproducible checks and explicit external gates.

- [ ] **Step 1: Run CGRX changed-code verification**

For each canonical worktree, run `status`, `scan_risks(mode="changes")`, and `check_index_coverage` for every relied-on changed file. Validate candidates against source and tests; read all missed ranges directly.

- [ ] **Step 2: Run backend verification**

```bash
cd /Volumes/D/Projects/vpn-main/.worktrees/dynamic-server-catalog-api
go test ./internal/... -count=1
go vet ./internal/...
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 3: Run client verification**

```bash
cd /Volumes/D/Projects/mobile/vex-client/.worktrees/dynamic-server-catalog
npm run check
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Reconcile the dirty primary checkout without overwriting it**

```bash
git -C /Volumes/D/Projects/mobile/vex-client status --short
git diff --no-index /Volumes/D/Projects/mobile/vex-client/src/vpn/useVpnConnection.ts /Volumes/D/Projects/mobile/vex-client/.worktrees/dynamic-server-catalog/src/vpn/useVpnConnection.ts
```

If overlapping primary edits remain uncommitted, keep this branch review-ready and record integration as externally gated by their owner. Never copy over or revert those files.

- [ ] **Step 5: Push and open linked pull requests**

Link both PRs to IBO-119, record dependency on PR #350 or its integrated successor, and keep deployment state separate from local verification.

---

### Task 7: Signed physical Android and staged production acceptance

**Files:**
- Update: private verification artifact outside Git
- Update: Linear IBO-119 with sanitized evidence

**Interfaces:**
- Consumes: signed Android candidate, deployed additive API, managed NL location.
- Produces: physical E2E and staged rollout decision.

- [ ] **Step 1: Build and verify the signed candidate**

Use the normal release script and signer allowlist. Confirm package `com.vexguard.app`, incremented version, signer match, and upgrade installation without clearing account data.

- [ ] **Step 2: Prove dynamic appearance without rebuilding the APK**

Capture a catalog with the scoped test location unavailable, then enable the compatible NL location through the reversible backend management path. Foreground the already installed candidate or open the picker and verify NL appears.

- [ ] **Step 3: Connect to NL in VEX**

On device `4ba9ae7d9805`, verify:

```text
Android VPN network: CONNECTED
tunnel address and DNS: present
external IP: 79.137.197.215
DNS and HTTPS: succeed
ICMP sample: 0% packet loss
server peer: fresh handshake and increasing RX/TX counters
```

Disconnect and reconnect once. Inspect Android crash buffer and NL journals for warning/error, MTU, OOM, panic, and restart signals.

- [ ] **Step 4: Verify authoritative retirement**

Retire or hide only the scoped test location through the reversible management path. Refresh the picker and verify it is no longer selectable. Refresh alone must not terminate an already active tunnel.

- [ ] **Step 5: Stage rollout and record evidence**

Deploy API first, then signed client canary. Observe refresh errors, empty snapshots, connection success, crash-free sessions, and node health before broad rollout. Update IBO-119 with commits, PRs, exact checks, signed identity, physical E2E, deployed revision, soak status, rollback, and remaining gates.

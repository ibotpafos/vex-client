import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeLocationCatalog } from '../src/vpn/locationCatalog.ts';
import { chooseBestVpnLocation, isSelectableLocation, reconcileLocationSelection } from '../src/vpn/serverSelection.ts';
import { profileResolutionOrder } from '../src/vpn/profileResolutionFallback.ts';
import { countryGroups, isLocationAvailable, stableCountryGroups } from '../src/screens/country-groups.ts';
import { serverPickerRowPresentation } from '../src/screens/server-picker-interactions.ts';
import { stableHomeLocationPreviews } from '../src/screens/home-location-previews.ts';
import { createLocationCatalogRefresher } from '../src/vpn/locationCatalogRefresh.ts';
import { locationCatalogCacheSchemaVersion, validCachedValueForUser } from '../src/vpn/vpnQueryCachePolicy.ts';

const location = (id, extra = {}) => ({
  id, countryCode: 'DE', city: id, displayName: id, availability: 'available',
  status: 'healthy', healthyNodes: 2, priority: 1, capabilities: [], ...extra,
});
const wireLocation = (id) => ({
  id, country_code: 'DE', city: id, availability: 'available', status: 'healthy', healthy_nodes: 2,
});

test('wire AWG3 capacity survives the domain projection, including explicit zero and legacy absence', () => {
  const catalog = normalizeLocationCatalog([
    { ...wireLocation('zero'), awg3_nodes: 0 },
    { ...wireLocation('ready'), awg3_nodes: 2 },
    wireLocation('legacy'),
  ]);
  assert.deepEqual(Object.fromEntries(catalog.map(item => [item.id, item.awg3Nodes])), { legacy: undefined, ready: 2, zero: 0 });
  assert.equal(chooseBestVpnLocation(catalog)?.id, 'legacy');
});

test('malformed AWG3 counts fail catalog validation instead of becoming legacy compatibility', () => {
  for (const count of [null, '0', -1, 0.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => normalizeLocationCatalog([
      { ...wireLocation('invalid'), awg3_nodes: count },
    ]), /invalid awg3_nodes/);
  }
});

test('automatic and manual selection, country cards and picker rows share capability and availability', () => {
  const ready = location('ready', { awg3Nodes: 1, latencyMs: 30 });
  for (const extra of [
    { awg3Nodes: 0 }, { awg3Nodes: -1 }, { awg3Nodes: Number.NaN },
    { availability: 'hidden' }, { availability: 'maintenance' }, { availability: 'retired' },
    { status: 'offline' }, { status: 'unknown' }, { healthyNodes: 0 },
    { status: undefined }, { availability: null },
  ]) {
    const denied = location('denied', { awg3Nodes: 1, latencyMs: 1, ...extra });
    assert.equal(isSelectableLocation(denied), false, JSON.stringify(extra));
    assert.equal(isLocationAvailable(denied), false, JSON.stringify(extra));
    assert.equal(serverPickerRowPresentation(denied, { busy: false, selected: false }).disabled, true);
    assert.equal(chooseBestVpnLocation([denied, ready])?.id, ready.id);
    assert.deepEqual(profileResolutionOrder(denied.id, [denied, ready]).map(item => item.id), [ready.id]);
    assert.deepEqual(reconcileLocationSelection('manual', denied.id, [denied, ready]), { mode: 'auto', selectedLocationId: ready.id });
    assert.equal(countryGroups([denied, ready], '')[0].availableNodeCount, ready.healthyNodes);
  }
  for (const extra of [{}, { awg3Nodes: 2 }, { status: ' Degraded ' }, { availability: ' AVAILABLE ', status: ' Online ' }]) {
    assert.equal(isSelectableLocation(location('legacy-or-ready', extra)), true);
    assert.equal(isLocationAvailable(location('legacy-or-ready', extra)), true);
  }
});

test('capability-only changes replace country and home card snapshots without latency churn', () => {
  const first = location('ready', { awg3Nodes: 1 });
  const changed = { ...first, awg3Nodes: 2 };
  const groups = countryGroups([first], first.id);
  assert.notEqual(stableCountryGroups(groups, countryGroups([changed], changed.id)), groups);
  const previews = [first];
  assert.notEqual(stableHomeLocationPreviews(previews, [changed], changed), previews);
  assert.equal(stableHomeLocationPreviews(previews, [{ ...first, latencyMs: 50 }], first), previews);
});

test('a capacity-only network refresh publishes the new catalog and rejects its zero-capacity target', async () => {
  const initial = [location('ready', { awg3Nodes: 1 })];
  let current = initial;
  const next = [{ ...initial[0], awg3Nodes: 0 }];
  const committed = [];
  const refresher = createLocationCatalogRefresher({
    currentCatalog: () => current,
    fetchCatalog: async () => next,
    commitCatalog: catalog => { committed.push(catalog); current = catalog; },
  });
  const result = await refresher.refresh('interval');
  assert.equal(result.locations, next);
  assert.deepEqual(committed, [next]);
  assert.equal(chooseBestVpnLocation(result.locations), undefined);
  await refresher.refresh('interval');
  assert.equal(committed.length, 1, 'unchanged capacity should preserve catalog identity');
});

test('old cached catalogs that discarded capacity must be refreshed while current legacy responses remain supported', () => {
  assert.equal(locationCatalogCacheSchemaVersion, 3);
  const value = [location('legacy')];
  const isCatalog = (input) => Array.isArray(input);
  const old = { savedAtMs: 1, schemaVersion: 2, userId: 'fixture-owner', value };
  assert.equal(validCachedValueForUser(old, 'fixture-owner', locationCatalogCacheSchemaVersion, isCatalog), null);
  assert.equal(validCachedValueForUser({ ...old, schemaVersion: locationCatalogCacheSchemaVersion }, 'fixture-owner', locationCatalogCacheSchemaVersion, isCatalog), value);
});

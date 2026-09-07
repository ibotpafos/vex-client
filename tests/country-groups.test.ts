import { countryGroups, availableNodeCountText, isLocationAvailable, stableCountryGroups } from '../src/screens/country-groups';
import { serverPickerActionForSource } from '../src/screens/server-picker-interactions';
import type { VpnLocation } from '../src/api/types';
const assert = {
  equal(actual: unknown, expected: unknown) {
    if (!Object.is(actual, expected)) throw new Error(`Expected ${String(expected)}, received ${String(actual)}`);
  },
  deepEqual(actual: unknown, expected: unknown) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  },
};
const location = (id: string, countryCode = 'DE', extra: Partial<VpnLocation> = {}): VpnLocation => ({ id, countryCode, city: id, displayName: id, flagEmoji: '', availability: 'available', priority: 0, status: 'healthy', healthyNodes: 1, capabilities: [], ...extra });
const features = location('de-features', ' de ', { city: 'AWG 3.1 Features', healthyNodes: 2 });
const selected = location('de-offline', 'DE', { status: 'offline', healthyNodes: 7 });
const input = [features, location('de-normal'), features, location('fi', 'FI'), selected];
const groups = countryGroups(input, selected.id, selected);
assert.equal(groups.length, 2);
assert.equal(groups[0].availableNodeCount, 3);
assert.equal(groups[0].representative.id, selected.id);
assert.equal(groups[0].representative.latencyMs, undefined);
assert.equal(groups[0].isSelected, true);
assert.equal(groups[0].locations.find(x => x.id === features.id)?.city, 'AWG 3.1 Features');
assert.deepEqual(countryGroups(input, 'fi', undefined, 1).map(x => x.id), ['country:FI']);
assert.equal(countryGroups([location('unknown-a', ''), location('unknown-b', '?')], '').length, 2);
assert.equal(countryGroups([features], selected.id, selected)[0].locations.length, 2);
assert.equal(countryGroups([], '').length, 0);
assert.equal(countryGroups(input, '', undefined, 0).length, 0);
const firstSnapshot = countryGroups(input, selected.id, selected);
const equivalentSnapshot = countryGroups(input.map(item => ({ ...item })), selected.id, { ...selected });
const stableSnapshot = stableCountryGroups(firstSnapshot, equivalentSnapshot);
assert.equal(stableSnapshot, firstSnapshot);
assert.equal(stableSnapshot[0], firstSnapshot[0]);
const changedSnapshot = countryGroups(input.map(item => item.id === 'fi' ? { ...item, healthyNodes: 2 } : { ...item }), selected.id, { ...selected });
const partiallyStableSnapshot = stableCountryGroups(firstSnapshot, changedSnapshot);
assert.equal(partiallyStableSnapshot[0], firstSnapshot[0]);
assert.equal(partiallyStableSnapshot[1] === firstSnapshot[1], false);
const selectionOrderInput = [location('de', 'DE'), location('fi', 'FI'), location('nl', 'NL')];
const initialSelectionOrder = countryGroups(selectionOrderInput, 'de');
const reorderedBySelection = countryGroups(selectionOrderInput, 'nl');
const stableSelectionOrder = stableCountryGroups(initialSelectionOrder, reorderedBySelection);
assert.deepEqual(stableSelectionOrder.map(group => group.id), initialSelectionOrder.map(group => group.id));
assert.equal(stableSelectionOrder.find(group => group.id === 'country:NL')?.isSelected, true);
for (const availability of ['maintenance', 'unavailable', 'retired']) assert.equal(isLocationAvailable(location('x', 'DE', { availability })), false);
for (const status of ['offline', 'unknown']) assert.equal(isLocationAvailable(location('x', 'DE', { status })), false);
for (const healthyNodes of [-1, NaN, Infinity, 0]) assert.equal(isLocationAvailable(location('x', 'DE', { healthyNodes })), false);
assert.equal(isLocationAvailable(location('x', 'DE', { status: ' Degraded ' })), true);
assert.deepEqual([0,1,2,5,11,21,22,25,111].map(availableNodeCountText), ['0 узлов','1 узел','2 узла','5 узлов','11 узлов','21 узел','22 узла','25 узлов','111 узлов']);
assert.equal(serverPickerActionForSource('carousel'), 'open_picker');
assert.equal(serverPickerActionForSource('all_locations'), 'open_picker');
console.log('PASS country grouping: normalized/deduplicated, counts, selected retention, unknown separation, limits, statuses, plurals, picker-only taps');

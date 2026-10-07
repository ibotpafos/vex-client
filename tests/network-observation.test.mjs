import assert from 'node:assert/strict';
import { test } from 'node:test';
import { matchingNetworkObservation } from '../src/diagnostics/networkObservation';

test('session network reference expires and is invalidated on network or device change', () => {
  const network = { networkClass: 'cellular', generation: 'fixture-generation' };
  const captured = { ...network, id: 'fixture-observation', deviceId: 'fixture-device', capturedAt: 1_000 };
  assert.equal(matchingNetworkObservation(captured, network, captured.deviceId, 2_000), captured.id);
  assert.equal(matchingNetworkObservation(captured, { ...network, generation: 'changed' }, captured.deviceId, 2_000), undefined);
  assert.equal(matchingNetworkObservation(captured, { ...network, networkClass: 'wifi' }, captured.deviceId, 2_000), undefined);
  assert.equal(matchingNetworkObservation(captured, network, 'other-device', 2_000), undefined);
  assert.equal(matchingNetworkObservation(captured, network, captured.deviceId, 0), undefined);
  assert.equal(matchingNetworkObservation(captured, network, captured.deviceId, 6 * 60 * 60 * 1000 + 1_001), undefined);
  assert.equal(matchingNetworkObservation(null, network, captured.deviceId, 2_000), undefined);
});

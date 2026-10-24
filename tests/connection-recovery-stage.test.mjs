import assert from 'node:assert/strict';
import test from 'node:test';
import { ApiRequestError, requestCancelledError } from '../src/api/error.ts';
import { recoverVpnConnection } from '../src/vpn/connectionRecovery.ts';
import { isVpnTransportFallbackError } from '../src/vpn/connectionFallback.ts';

function profile(id, locationId = 'de') {
  return { id, locationId, config: `Endpoint = ${locationId}.example.test:51820` };
}

function fixture(stage, failure) {
  const activeProfile = profile('active');
  const calls = [];
  const mutations = [];
  const input = {
    activeLocationId: 'de', activeProfile,
    availableLocations: ['de', 'fi'].map(id => ({ id, availability: 'available', status: 'online', healthyNodes: 1 })),
    connectProfile: async candidate => {
      calls.push(`connect:${candidate.id}`);
      if (candidate === activeProfile) {
        throw new Error(stage === 'initial rotation' ? 'profile config invalid public key' : 'handshake timeout');
      }
      if (stage === 'fresh rotation' && candidate.id === 'fresh') throw new Error('profile config invalid public key');
      return { profile: candidate, status: { state: 'connected' } };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    resolveProfile: async (locationId, options) => {
      calls.push(`resolve:${locationId}`);
      assert.equal(options.forceRefresh, true);
      mutations.push(`issue:${locationId}`); // The remote change precedes the lost response.
      if (stage === 'fresh issuance' && locationId === 'de') throw failure;
      return profile(locationId === 'de' ? 'fresh' : 'failover', locationId);
    },
    rotateProfile: async candidate => {
      calls.push(`rotate:${candidate.id}`);
      mutations.push(`rotate:${candidate.id}`);
      throw failure;
    },
    persistLocation: async locationId => { calls.push(`persist:${locationId}`); return locationId; },
    setCachedProfile: locationId => { calls.push(`cache:${locationId}`); },
  };
  return { input, calls, mutations };
}

for (const stage of ['fresh issuance', 'initial rotation', 'fresh rotation']) {
  for (const [name, createError] of [
    ['reset after remote commit', () => new Error('connection reset by peer')],
    ['upstream timeout', () => new ApiRequestError('connection timed out', { status: 503 })],
    ['unreachable response path', () => new Error('network is unreachable')],
    ['caller cancellation', requestCancelledError],
  ]) {
    test(`${stage} stops after ${name} without another issuance or rotation`, async () => {
      const failure = createError();
      const { input, calls, mutations } = fixture(stage, failure);
      const result = await recoverVpnConnection(input);
      assert.equal(result.ok, false);
      assert.equal(result.error, failure, 'preserve the actual preparation failure');
      assert.equal(result.profile, input.activeProfile);
      assert.equal(result.status, null);
      assert.equal(result.locationId, 'de');
      assert.deepEqual(calls, stage === 'fresh issuance'
        ? ['connect:active', 'resolve:de']
        : stage === 'initial rotation'
          ? ['connect:active', 'rotate:active']
          : ['connect:active', 'resolve:de', 'connect:fresh', 'rotate:fresh']);
      assert.deepEqual(mutations, stage === 'fresh issuance'
        ? ['issue:de']
        : stage === 'initial rotation' ? ['rotate:active'] : ['issue:de', 'rotate:fresh']);
    });
  }
}

for (const stage of ['fresh issuance', 'initial rotation', 'fresh rotation']) {
  test(`${stage} can still fail over after a returned profile's actual connection fails`, async () => {
    const { input, calls, mutations } = fixture(stage, undefined);
    input.resolveProfile = async locationId => {
      calls.push(`resolve:${locationId}`); mutations.push(`issue:${locationId}`);
      return profile(locationId === 'de' ? 'fresh' : 'failover', locationId);
    };
    input.rotateProfile = async candidate => {
      calls.push(`rotate:${candidate.id}`); mutations.push(`rotate:${candidate.id}`);
      return profile('rotated');
    };
    const connect = input.connectProfile;
    input.connectProfile = async candidate => {
      if ((stage === 'fresh issuance' && candidate.id === 'fresh') || candidate.id === 'rotated') {
        calls.push(`connect:${candidate.id}`); throw new Error('handshake timeout');
      }
      return connect(candidate);
    };
    const result = await recoverVpnConnection(input);
    assert.equal(result.ok, true);
    assert.equal(result.outcome, 'failover_location');
    assert.equal(result.locationId, 'fi');
    const preparation = stage === 'fresh issuance'
      ? ['connect:active', 'resolve:de', 'connect:fresh']
      : stage === 'initial rotation'
        ? ['connect:active', 'rotate:active', 'connect:rotated']
        : ['connect:active', 'resolve:de', 'connect:fresh', 'rotate:fresh', 'connect:rotated'];
    assert.deepEqual(calls, [...preparation, 'resolve:fi', 'connect:failover', 'persist:fi', 'cache:fi']);
    assert.deepEqual(mutations, stage === 'fresh issuance' ? ['issue:de', 'issue:fi']
      : stage === 'initial rotation' ? ['rotate:active', 'issue:fi'] : ['issue:de', 'rotate:fresh', 'issue:fi']);
  });
}

for (const failing of ['none', 'preparation', 'connect']) test('key admission reconciliation stops at ' + failing + ' without rotation or failover', async () => {
  const { input, calls } = fixture('fresh issuance', undefined);
  const changed = Object.assign(new Error('Key changed'), { code: 'VPN_PROFILE_KEY_CHANGED' });
  const failed = new ApiRequestError('connection timed out', { status: 503 });
  input.connectProfile = async candidate => {
    calls.push('connect:' + candidate.id);
    if (candidate === input.activeProfile) throw changed;
    if (failing === 'connect') throw failed;
    return { profile: candidate, status: { state: 'connected' } };
  };
  input.resolveProfile = async (location, options) => {
    calls.push('resolve:' + location); assert.equal(options.forceRefresh, true);
    assert.equal(options.requestPermission, false);
    if (failing === 'preparation') throw failed;
    return profile('fresh', location);
  };
  const result = await recoverVpnConnection(input);
  assert.equal(result.ok, failing === 'none');
  if (failing !== 'none') assert.equal(result.error, failed);
  else assert.equal(result.outcome, 'same_location_fresh_profile');
  assert.deepEqual(calls, failing === 'preparation' ? ['connect:active', 'resolve:de']
    : failing === 'connect' ? ['connect:active', 'resolve:de', 'connect:fresh']
      : ['connect:active', 'resolve:de', 'connect:fresh', 'cache:de']);
});

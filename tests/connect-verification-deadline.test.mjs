import assert from 'node:assert/strict';
import test from 'node:test';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification.ts';

const pending = { state: 'connected', rxBytes: 0, txBytes: 0, verified: false };

test('a ready fresh handshake is read before the first polling delay', async () => {
  const result = await waitForVerifiedVpnConnection(pending, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: 1000,
  }), {
    minimumHandshakeEpochMillis: 1000,
    wait: async () => { throw new Error('unnecessary initial polling delay'); },
  });
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('an old handshake still waits and cannot satisfy a new attempt', async () => {
  let reads = 0;
  let waits = 0;
  const result = await waitForVerifiedVpnConnection(pending, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: ++reads === 1 ? 900 : 1000,
  }), {
    minimumHandshakeEpochMillis: 1000,
    wait: async () => { waits++; },
  });
  assert.equal(waits, 1);
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('a stalled native status read cannot hold connection verification forever', async () => {
  const verification = waitForVerifiedVpnConnection(pending, () => new Promise(() => {}), {
    pollMs: 0, timeoutMs: 20,
  });
  let safetyTimer;
  const safety = new Promise((_, reject) => {
    safetyTimer = setTimeout(() => reject(new Error('test safety deadline exceeded')), 500);
  });
  try {
    await assert.rejects(Promise.race([verification, safety]), /VPN handshake timed out/);
  } finally { clearTimeout(safetyTimer); }
});

test('a status returned after suspension cannot be accepted beyond the deadline', async () => {
  let now = 100;
  await assert.rejects(waitForVerifiedVpnConnection(pending, async () => {
    now += 60_000;
    return { ...pending, verified: true };
  }, { pollMs: 0, timeoutMs: 1000, now: () => now }), /VPN handshake timed out/);
});

test('a current handshake within the deadline succeeds', async () => {
  const status = await waitForVerifiedVpnConnection(pending, async () => ({ ...pending, verified: true }), {
    pollMs: 0, timeoutMs: 1000,
  });
  assert.equal(status.verified, true);
});

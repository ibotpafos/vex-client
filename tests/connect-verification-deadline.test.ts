import assert from 'node:assert/strict';
import test from 'node:test';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification';

const pending = { state: 'connected' as const, rxBytes: 0, txBytes: 0, verified: false };

test('a stalled native status read cannot hold connection verification forever', async () => {
  const verification = waitForVerifiedVpnConnection(pending, () => new Promise(() => {}), {
    pollMs: 0, timeoutMs: 20,
  });
  let safetyTimer: ReturnType<typeof setTimeout>;
  const safety = new Promise((_, reject) => {
    safetyTimer = setTimeout(() => reject(new Error('test safety deadline exceeded')), 500);
  });
  try {
    await assert.rejects(Promise.race([verification, safety]), /VPN handshake timed out/);
  } finally { clearTimeout(safetyTimer!); }
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

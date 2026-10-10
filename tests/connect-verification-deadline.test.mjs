import assert from 'node:assert/strict';
import test from 'node:test';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification.ts';

const pending = { state: 'connected', rxBytes: 0, txBytes: 0, verified: false };

for (const state of ['connecting', 'verifying']) {
  test(`an initial ${state} status without verification fields cannot return early`, async () => {
    let reads = 0;
    const result = await waitForVerifiedVpnConnection({ state, rxBytes: 0, txBytes: 0 }, async () => {
      reads++;
      return { ...pending, verified: true };
    });
    assert.equal(reads, 1);
    assert.equal(result.state, 'connected');
  });

  test(`an initial ${state} status waits for a fresh verified connection`, async () => {
    let reads = 0;
    const result = await waitForVerifiedVpnConnection({ ...pending, state, verified: true }, async () => {
      reads++;
      return reads === 1
        ? { ...pending, state }
        : { ...pending, verified: true, latestHandshakeEpochMillis: 1000 };
    }, { minimumHandshakeEpochMillis: 1000, pollMs: 0 });
    assert.equal(reads, 2);
    assert.equal(result.state, 'connected');
    assert.equal(result.latestHandshakeEpochMillis, 1000);
  });

  test(`an initial ${state} status retains the verification deadline`, async () => {
    await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state }, () => new Promise(() => {}), {
      timeoutMs: 20,
    }), /VPN handshake timed out/);
  });
}

for (const state of ['disconnected', 'disconnecting', 'error']) {
  test(`an initial ${state} status rejects without polling`, async () => {
    let reads = 0;
    await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state }, async () => {
      reads++;
      return { ...pending, verified: true };
    }), /VPN backend did not enter/);
    assert.equal(reads, 0);
  });
}

test('an iOS extension may still be connecting when startVPNTunnel returns', async () => {
  const result = await waitForVerifiedVpnConnection({ ...pending, state: 'connecting' }, async () => ({
    ...pending, verified: true, latestHandshakeEpochMillis: 1000,
  }), { minimumHandshakeEpochMillis: 1000, pollMs: 0 });
  assert.equal(result.latestHandshakeEpochMillis, 1000);
});

test('a starting extension still needs a handshake before the same deadline', async () => {
  await assert.rejects(waitForVerifiedVpnConnection({ ...pending, state: 'connecting' }, async () => ({
    ...pending, state: 'connecting',
  }), { attempts: 2, pollMs: 0 }), /VPN handshake timed out/);
});

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

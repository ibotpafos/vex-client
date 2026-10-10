import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveNativeTunnelVerified } from '../src/vpn/vpnStatusVerification.ts';

test('iOS interface state and sent traffic cannot replace a native handshake', () => {
  for (const counters of [{ rxBytes: 0, txBytes: 0 }, { rxBytes: 0, txBytes: 2048 }, { rxBytes: 2048, txBytes: 2048 }]) {
    assert.equal(resolveNativeTunnelVerified({
      state: 'connected', ...counters, verified: true, latestHandshakeEpochMillis: 0,
    }, 'ios'), false);
  }
});

test('a native iOS handshake supplies the proof used by connection verification', () => {
  assert.equal(resolveNativeTunnelVerified({
    state: 'connected', rxBytes: 0, txBytes: 0, latestHandshakeEpochMillis: 123_000,
  }, 'ios'), true);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveNativeTunnelVerified } from '../src/vpn/vpnStatusVerification.ts';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification.ts';
import { assessNativeTunnelHealth } from '../src/vpn/nativeTunnelHealth.ts';
import { localStatusHealthReasons } from '../src/vpn/nativeTunnelHealth.ts';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { assessVpnAutopilotIssue } from '../src/vpn/vpnAutopilotAssessment.ts';

const handshake = { state: 'connected', rxBytes: 4096, txBytes: 8192, latestHandshakeEpochMillis: 1000, verified: true };

test('Android handshake, counters and a legacy native verified flag cannot replace DNS/HTTPS', () => {
  assert.equal(resolveNativeTunnelVerified(handshake, 'android'), false);
  assert.equal(resolveNativeTunnelVerified({ ...handshake, dataPlaneVerified: false }, 'android'), false);
  assert.equal(resolveNativeTunnelVerified({ ...handshake, dataPlaneVerified: true }, 'android'), true);
  assert.equal(resolveNativeTunnelVerified({ ...handshake, dataPlaneVerified: true, verified: false }, 'android'), false);
  assert.equal(resolveNativeTunnelVerified({ ...handshake, dataPlaneVerified: true, latestHandshakeEpochMillis: 0 }, 'android'), false);
});

test('Android connection waits for both real traffic checks after the fresh handshake', async () => {
  let reads = 0;
  const result = await waitForVerifiedVpnConnection(handshake, async () => ({
    ...handshake, dataPlaneVerified: ++reads >= 3,
  }), { requireDataPlane: true, minimumHandshakeEpochMillis: 1000, pollMs: 0 });
  assert.equal(reads, 3);
  assert.equal(result.dataPlaneVerified, true);
});

test('an old binary or failed DNS/HTTPS cannot produce connected acceptance', async () => {
  for (const dataPlaneVerified of [undefined, false]) {
    await assert.rejects(waitForVerifiedVpnConnection({ ...handshake, dataPlaneVerified }, async () => handshake, {
      requireDataPlane: true, attempts: 2, pollMs: 0,
    }), /verification|handshake/i);
  }
});

test('a canceled selection cannot accept late DNS/HTTPS success', async () => {
  let current = true;
  await assert.rejects(waitForVerifiedVpnConnection(handshake, async () => {
    current = false;
    return { ...handshake, dataPlaneVerified: true };
  }, {
    requireDataPlane: true,
    assertCurrent: () => { if (!current) throw new Error('superseded'); },
  }), /superseded/);
});

test('a failed data plane triggers recovery even with a fresh handshake', () => {
  for (const verificationReason of ['dns_failed', 'https_failed', 'data_plane_unavailable']) {
    const health = assessNativeTunnelHealth({ nowMs: 1100, staleHandshakeSeconds: 180,
      status: { ...handshake, verified: false, dataPlaneVerified: false, verificationReason },
    });
    assert.equal(health.healthy, false);
    assert.ok(health.reasons.includes('data_plane_failed'));
  }
  assert.equal(assessNativeTunnelHealth({ nowMs: 1100, staleHandshakeSeconds: 180,
    status: { ...handshake, verified: false, dataPlaneVerified: false, verificationReason: 'data_plane_pending' },
  }).healthy, true, 'pending verification must not cause a reconnect loop');
});

test('watchdog records failed traffic without freezing the previous connected UI', () => {
  const source = stripTypeScriptTypes(readFileSync('src/vpn/useNativeVpnWatchdog.ts', 'utf8'))
    .replace(/import[\s\S]*?from '[^']+';/g, '').replace('export function useNativeVpnWatchdog', 'function useNativeVpnWatchdog');
  const stubs = { useRef: value => ({current: value}), useCallback: fn => fn, useEffect: () => {},
    localStatusHealthReasons, initialRecoveryBackoffState: () => ({}), vpnUnexpectedDisconnectTelemetry: () => null };
  const hook = new Function(...Object.keys(stubs), source + ';return useNativeVpnWatchdog;')(...Object.values(stubs));
  const watchdog = hook({ activeProfile: {locationId: 'nl', device: {id: 'fixture'}},
    staleHandshakeSeconds: 180, submitDiagnostics: async () => {}, reportConnect: () => {} });
  for (const state of ['connected', 'error', 'disconnected']) {
    assert.equal(watchdog.recordNativeStatus(handshake, { ...handshake, state, latestHandshakeEpochMillis: Date.now(),
      verified: false, dataPlaneVerified: false, verificationReason: 'https_failed',
    }), false, 'native unverified proof must reach the UI while recovery is scheduled');
  }
});

test('HTTPS failure and admission timeout do not misclassify DNS or authorize a location change', () => {
  assert.equal(assessVpnAutopilotIssue({localStatus: {...handshake, verificationReason: 'https_failed'}}).cause, 'network');
  assert.equal(assessVpnAutopilotIssue({error: new Error('VPN traffic verification timed out.')}).canFailover, false);
  assert.equal(assessVpnAutopilotIssue({localStatus: {...handshake, verificationReason: 'dns_failed'}}).cause, 'dns');
});

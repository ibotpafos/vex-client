import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { resolveNativeTunnelVerified } from '../src/vpn/vpnStatusVerification.ts';

const source = stripTypeScriptTypes(readFileSync('src/native/vexVpn.ts', 'utf8'))
  .replace(/import[\s\S]*?from '[^']+';/g, '').replace(/\bexport (?=(?:async )?function)/g, '');
const old = { state: 'connected', rxBytes: 0, txBytes: 0, latestHandshakeEpochMillis: 1000,
  verified: true, dataPlaneVerified: true, dataPlaneGeneration: 'previous-peer' };
const pending = { ...old, verified: false, dataPlaneVerified: false, dataPlaneGeneration: 'new-peer' };
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; }
function moduleAPI(native) {
  const stubs = { NativeModules: {VexVpn: native}, Platform: {OS: 'android'}, NativeEventEmitter: class {},
    requireExpoNativeModule: () => { throw new Error('unexpected Expo fallback'); }, resolveNativeTunnelVerified,
    nativeRoutingParameters: () => '{}', disconnectWithRecoveryTimeout: operation => operation };
  return new Function(...Object.keys(stubs), source + ';return {connectVpn, disconnectVpn, getVpnStatus};')(...Object.values(stubs));
}

for (const control of ['connect', 'disconnect']) {
  test(`an older read cannot overwrite the cache after ${control}`, async () => {
    const read = deferred(); let reads = 0;
    const next = control === 'connect' ? pending : {...pending, state: 'disconnected'};
    const api = moduleAPI({status: () => { reads++; return read.promise; }, connect: async () => next, disconnect: async () => next});
    const previous = api.getVpnStatus();
    if (control === 'connect') await api.connectVpn('fixture'); else await api.disconnectVpn();
    read.resolve(old); await previous;
    const current = await api.getVpnStatus();
    assert.equal(current.dataPlaneGeneration, 'new-peer');
    assert.equal(current.verified, false);
    assert.equal(current.state, next.state);
    assert.equal(reads, 1);
  });
}

test('an old read finalizer cannot detach the newer in-flight status read', async () => {
  const previous = deferred(), current = deferred(), connect = deferred(); let reads = 0;
  const api = moduleAPI({status: () => ++reads === 1 ? previous.promise : current.promise, connect: () => connect.promise});
  const oldRead = api.getVpnStatus();
  const connection = api.connectVpn('fixture');
  const newRead = api.getVpnStatus();
  previous.resolve(old); await oldRead;
  const shared = api.getVpnStatus();
  assert.equal(reads, 2, 'the new read must remain shared');
  current.resolve(pending);
  assert.equal((await newRead).dataPlaneGeneration, 'new-peer');
  assert.equal((await shared).dataPlaneGeneration, 'new-peer');
  connect.resolve(pending); await connection;
});

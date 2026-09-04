import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const path = process.argv[2] ?? new URL('../src/vpn/connectVerification.ts', import.meta.url);
const source = stripTypeScriptTypes(readFileSync(path, 'utf8').replace(/^import type .*;\n/gm, ''));
const { waitForVerifiedVpnConnection: verify } = await import(`data:text/javascript,${encodeURIComponent(source)}`);
const pending = { state: 'connected', verified: false, rxBytes: 0, txBytes: 0 };
const fresh = { ...pending, verified: true, latestHandshakeEpochMillis: 20_000 };
const options = { attempts: 3, pollMs: 0, wait: async () => {}, minimumHandshakeEpochMillis: 15_000 };
// Native status polling can publish a connecting snapshot while another reader
// owns tunnelMutex. Such a snapshot is not evidence of a disconnected tunnel.
let states = ['connecting', 'verifying', 'connected'];
assert.deepEqual(await verify(pending, async () => ({ ...fresh, state: states.shift() }), options), fresh);
for (const state of ['connecting', 'verifying']) {
  await assert.rejects(verify(pending, async () => ({ ...fresh, state }), options), /handshake timed out/);
}
for (const state of ['disconnected', 'disconnecting', 'error', 'degraded']) {
  let reads = 0;
  await assert.rejects(verify(pending, async () => { reads++; return { ...fresh, state }; }, options), /disconnected before/);
  assert.equal(reads, 1);
}
await assert.rejects(verify(pending, async () => ({ ...fresh, latestHandshakeEpochMillis: 10_000 }), options), /handshake timed out/);
console.log('HANDSHAKE_TRANSIENT_STATUS_MATRIX=PASS');

import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const source = stripTypeScriptTypes(fs.readFileSync('src/api/client.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
const errors = stripTypeScriptTypes(fs.readFileSync('src/api/error.ts', 'utf8')).replace(/\bexport /g, '');
const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
const reply = (body = 'fresh', status = 200, headers = {}) => ({ status, statusText: '', body, headers });
function client({ native, platform = 'android', base = 'https://vexguard.app', fetch, appInfo } = {}) {
  const calls = [];
  const normal = fetch ?? (async () => { calls.push('default'); return { ok: true, status: 200, text: async () => 'normal' }; });
  const api = new Function('fetch', 'getAppInfo', 'getOrCreateDeviceId', 'Platform', 'NativeModules',
    'androidExperimentalRoutingEnabled', 'androidProfilePlatform', 'process', errors + source
      + ';return {rawRequest, withProfileRecoveryTransport};')(
    normal, appInfo ?? (async () => ({})), async () => 'fixture', { OS: platform }, { VexVpn: native },
    () => false, () => 'android', { env: { EXPO_PUBLIC_VEX_API_BASE_URL: base } });
  return { ...api, calls };
}

test('a failed captured tunnel can fetch a fresh profile without releasing VPN protection', async () => {
  const requests = [];
  const api = client({
    fetch: async () => { throw new TypeError('Network request failed'); },
    native: { requestApiRecovery: async (...args) => { requests.push(args); return reply('{"profile":"fresh"}'); }, cancelApiRecovery() {} },
  });
  await assert.rejects(api.rawRequest('/v1/vpn/profile', { retryCount: 0 }));
  assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', {
    method: 'POST', accessToken: 'fixture-token', idempotencyKey: 'fixture-key', body: { location_id: 'fi' },
  })), '{"profile":"fresh"}');
  assert.equal(requests.length, 1);
  const [id, url, method, headers, body, deadline] = requests[0];
  assert.match(id, /^api-\d+-\d+$/);
  assert.equal(url, 'https://vexguard.app/v1/vpn/profile');
  assert.equal(method, 'POST');
  assert.equal(headers.Authorization, 'Bearer fixture-token');
  assert.equal(headers['Idempotency-Key'], 'fixture-key');
  assert.equal(body, '{"location_id":"fi"}');
  assert.ok(deadline > Date.now() && deadline <= Date.now() + 30_000);
});

for (const [name, native, platform] of [
  ['old native binary', undefined, 'android'],
  ['incomplete native ABI', { requestApiRecovery() { assert.fail('missing cancellation ABI'); } }, 'android'],
  ['other platform', { requestApiRecovery() { assert.fail('Android only'); }, cancelApiRecovery() {} }, 'ios'],
]) test(`${name} keeps the established API transport`, async () => {
  const api = client({ native, platform });
  assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile')), 'normal');
  assert.deepEqual(api.calls, ['default']);
});

for (const base of ['http://vexguard.app', 'https://vexguard.app.evil.test', 'https://evil.test',
  'https://vexguard.app:444', 'https://user:secret@vexguard.app']) {
  test(`recovery never bypasses captured routing for an untrusted origin: ${base}`, async () => {
    const api = client({ base, native: { requestApiRecovery() { assert.fail('untrusted origin'); }, cancelApiRecovery() {} } });
    assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile')), 'normal');
  });
}

for (const path of ['/dashboard', '/v1/../admin', '/v1/%2e%2e/admin', '/v1/%2f..%2fadmin', '/v1/vpn/profile#fragment']) {
  test(`only canonical API paths may use recovery transport: ${path}`, async () => {
    const api = client({ native: { requestApiRecovery() { assert.fail('non-API path'); }, cancelApiRecovery() {} } });
    assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest(path)), 'normal');
  });
}

test('scope teardown, including an exception, restores ordinary requests', async () => {
  let nativeCalls = 0;
  const api = client({ native: { requestApiRecovery: async () => { nativeCalls++; return reply(); }, cancelApiRecovery() {} } });
  await assert.rejects(api.withProfileRecoveryTransport(async () => { await api.rawRequest('/v1/vpn/profile'); throw new Error('fixture'); }), /fixture/);
  assert.equal(await api.rawRequest('/v1/vpn/profile'), 'normal');
  assert.equal(nativeCalls, 1);
});

test('authentication errors keep their status and never become a cached success', async () => {
  let count = 0;
  const api = client({ native: { requestApiRecovery: async () => { count++; return reply('{"message":"expired"}', 401); }, cancelApiRecovery() {} } });
  await assert.rejects(api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile')), error => error.status === 401);
  assert.equal(count, 1);
});

test('deadline cancels native I/O and ignores a late success', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let complete;
  const ids = [], cancelled = [];
  const api = client({ native: { requestApiRecovery: id => { ids.push(id); return new Promise(resolve => { complete = resolve; }); }, cancelApiRecovery: id => cancelled.push(id) } });
  const result = api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', { timeout: 1000 }));
  const rejected = assert.rejects(result, error => error.code === 'request_timeout');
  await settle(); t.mock.timers.tick(1000); await settle(); await rejected;
  assert.deepEqual(cancelled, ids);
  complete(reply('late')); await settle();
  assert.equal(await api.rawRequest('/v1/vpn/profile'), 'normal');
});

test('expired header setup cannot issue native I/O later', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let release, nativeCalls = 0;
  const api = client({ appInfo: () => new Promise(resolve => { release = resolve; }), native: {
    requestApiRecovery: async () => { nativeCalls++; return reply(); }, cancelApiRecovery() {},
  } });
  const result = assert.rejects(api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', { timeout: 1000 })));
  await settle(); t.mock.timers.tick(1000); await settle(); await result;
  release({}); await settle(); assert.equal(nativeCalls, 0);
});

test('a retry retains its selected network after the initiating scope ends', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let count = 0, pending;
  const api = client({ native: { requestApiRecovery: async () => ++count === 1 ? reply('{"message":"temporary"}', 503) : reply('recovered'), cancelApiRecovery() {} } });
  await api.withProfileRecoveryTransport(async () => { pending = api.rawRequest('/v1/vpn/profile', { timeout: 5000 }); await settle(); });
  t.mock.timers.tick(600); await settle();
  assert.equal(await pending, 'recovered'); assert.equal(count, 2); assert.deepEqual(api.calls, []);
});

test('native recovery preserves Retry-After and the original GET deadline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let count = 0;
  const api = client({ native: { requestApiRecovery: async () => ++count === 1
    ? reply('{"message":"wait"}', 429, { 'retry-after': '2' }) : reply(), cancelApiRecovery() {} } });
  const result = api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', { timeout: 5000 }));
  await settle(); t.mock.timers.tick(1999); await settle(); assert.equal(count, 1);
  t.mock.timers.tick(1); await settle(); assert.equal(await result, 'fresh'); assert.equal(count, 2);
});

test('native recovery does not replay a POST after HTTP failure', async () => {
  let count = 0;
  const api = client({ native: { requestApiRecovery: async () => { count++; return reply('{"message":"wait"}', 503); }, cancelApiRecovery() {} } });
  await assert.rejects(api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', {
    method: 'POST', idempotencyKey: 'fixture', retryCount: 20,
  })), error => error.status === 503);
  assert.equal(count, 1);
});

test('overlapping scopes cannot disable each other or leak into later requests', async () => {
  let releaseA, releaseB, count = 0;
  const a = new Promise(resolve => { releaseA = resolve; });
  const b = new Promise(resolve => { releaseB = resolve; });
  const api = client({ native: { requestApiRecovery: async () => { count++; return reply(); }, cancelApiRecovery() {} } });
  const first = api.withProfileRecoveryTransport(() => a);
  const second = api.withProfileRecoveryTransport(() => b);
  releaseA(); await first;
  assert.equal(await api.rawRequest('/v1/vpn/profile'), 'fresh');
  releaseB(); await second;
  assert.equal(await api.rawRequest('/v1/vpn/profile'), 'normal'); assert.equal(count, 1);
});

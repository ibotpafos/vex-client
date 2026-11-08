import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const origins = stripTypeScriptTypes(fs.readFileSync('src/api/origins.ts', 'utf8')).replace(/\bexport /g, '');
const source = origins + stripTypeScriptTypes(fs.readFileSync('src/api/client.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
const errors = stripTypeScriptTypes(fs.readFileSync('src/api/error.ts', 'utf8')).replace(/\bexport /g, '');
const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
const reply = (body = 'fresh', status = 200, headers = {}) => ({ status, statusText: '', body, headers });
function client({ native, platform = 'android', base = 'https://api.vexguard.app', fetch, appInfo } = {}) {
  const calls = [];
  const normal = fetch ?? (async () => { calls.push('default'); return { ok: true, status: 200, text: async () => 'normal' }; });
  const api = new Function('expoFetch', 'fetch', 'getAppInfo', 'getOrCreateDeviceId', 'Platform', 'NativeModules',
    'androidExperimentalRoutingEnabled', 'androidProfilePlatform', 'process', errors + source
      + ';return {rawRequest, withProfileRecoveryTransport};')(
    normal, normal, appInfo ?? (async () => ({})), async () => 'fixture', { OS: platform }, { VexVpn: native && { apiRecoveryPreservesHttpErrors: true, ...native } },
    () => false, () => 'android', { env: { EXPO_PUBLIC_VEX_API_BASE_URL: base } });
  return { ...api, calls };
}

test('a failed captured tunnel can fetch a fresh profile without releasing VPN protection', async () => {
  const requests = [];
  const api = client({
    fetch: async () => { throw new TypeError('Network request failed'); },
    native: { apiMutationNoReplay: true, requestApiMutation: async (...args) => { requests.push(args); return reply('{"profile":"fresh"}'); }, cancelApiMutation() {}, requestApiRecovery: async (...args) => { requests.push(args); return reply(); }, cancelApiRecovery() {} },
  });
  await assert.rejects(api.rawRequest('/v1/vpn/profile', { retryCount: 0 }));
  assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile', {
    method: 'POST', accessToken: 'fixture-token', idempotencyKey: 'fixture-key', body: { location_id: 'fi' },
  })), '{"profile":"fresh"}');
  assert.equal(requests.length, 2);
  assert.equal(requests[0][2], 'GET');
  assert.equal(requests[0][3].Authorization, undefined);
  const [id, url, method, headers, body, deadline] = requests[1];
  assert.match(id, /^api-\d+-\d+$/);
  assert.equal(url, 'https://api.vexguard.app/v1/vpn/profile');
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
]) test(`${name} uses ordinary Expo API transport`, async () => {
  const api = client({ native, platform });
  assert.equal(await api.withProfileRecoveryTransport(() => api.rawRequest('/v1/vpn/profile')), 'normal');
  assert.deepEqual(api.calls, ['default']);
});

for (const base of ['http://vexguard.app', 'https://vexguard.app.evil.test', 'https://evil.test',
  'https://vexguard.app:444', 'https://user:secret@vexguard.app']) {
  test(`recovery never bypasses captured routing for an untrusted origin: ${base}`, async () => {
    assert.throws(() => client({ base }), /Untrusted API origin/);
  });
}

for (const path of ['/dashboard', '/v1/../admin', '/v1/%2e%2e/admin', '/v1/%2f..%2fadmin', '/v1/vpn/profile#fragment']) {
  test(`only canonical API paths may use recovery transport: ${path}`, async () => {
    const api = client({ native: { requestApiRecovery() { assert.fail('non-API path'); }, cancelApiRecovery() {} } });
    await assert.rejects(api.withProfileRecoveryTransport(() => api.rawRequest(path)), /Invalid API path/);
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
  const rejected = assert.rejects(result, error => error.code === 'recovery_status_ambiguous');
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
  const api = client({ native: { apiMutationNoReplay: true, requestApiMutation: async () => { count++; return reply('{"message":"wait"}', 503); }, cancelApiMutation() {}, requestApiRecovery: async () => reply(), cancelApiRecovery() {} } });
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

test('reserve excluded by the shipped recovery allowlist uses Expo Fetch, never unsupported native recovery', async () => {
  const normal=[];let recovery=0;
  const api=client({fetch:async(url,init)=>{normal.push([url,init]);return {ok:true,status:200,text:async()=> 'reserve'};}, native:{
    requestApiRecovery:async()=>{recovery++;throw new TypeError('Network request failed');},cancelApiRecovery(){},
  }});
  assert.equal(await api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile')),'reserve');
  assert.equal(recovery,1);assert.equal(normal[0][0],'https://api2.vexguard.app/v1/vpn/profile');assert.equal(normal[0][1].redirect,'error');
});

test('new binaries advertise api2 recovery support; old binaries never infer it from generic failures', async () => {
  const calls=[];
  const api=client({fetch:async()=>assert.fail('new native reserve must retain recovery transport'),native:{
    apiRecoveryHosts:['api.vexguard.app','api2.vexguard.app','evil.test'],
    requestApiRecovery:async(_id,url)=>{calls.push(url);if(calls.length===1)throw new TypeError('Network request failed');return reply('reserve recovery');},
    cancelApiRecovery(){},
  }});
  assert.equal(await api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile')),'reserve recovery');
  assert.deepEqual(calls,['https://api.vexguard.app/v1/vpn/profile','https://api2.vexguard.app/v1/vpn/profile']);
});

test('advertised host subset is honored without widening the fixed first-party trust list',async()=>{
  let calls=0;
  const api=client({native:{apiRecoveryHosts:[],requestApiRecovery:async()=>{calls++;return reply();},cancelApiRecovery(){}}});
  assert.equal(await api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile')),'normal');assert.equal(calls,0);
});

for(const guarantee of [undefined,false])test(`legacy native generic recovery failure is terminal when status guarantee=${guarantee}`,async()=>{
  let calls=0;
  const api=client({fetch:()=>assert.fail('ambiguous denial must not escape to ordinary transport'),native:{apiRecoveryPreservesHttpErrors:guarantee,
    requestApiRecovery:async()=>{calls++;throw new Error('Network request failed');},cancelApiRecovery(){},
  }});
  await assert.rejects(api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile',{accessToken:'fixture'})),e=>e.code==='recovery_status_ambiguous');assert.equal(calls,1);
});

test('new native recovery preserves an empty denial body and Retry-After without retry or alias',async()=>{
  let calls=0;
  const api=client({fetch:()=>assert.fail('denial must not alias'),native:{apiRecoveryPreservesHttpErrors:true,
    requestApiRecovery:async()=>{calls++;return reply('',429,{'Retry-After':'120'});},cancelApiRecovery(){},
  }});
  await assert.rejects(api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile',{accessToken:'fixture',timeout:1000})),e=>e.status===429&&e.retryAfterMs===120000);assert.equal(calls,1);
});

for(const retryCount of [0,2])test(`legacy recovery timeout is status-ambiguous even at whole deadline (retryCount=${retryCount})`,async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0,cancelled=0;
  const api=client({fetch:()=>assert.fail('timeout must not escape or alias'),native:{apiRecoveryPreservesHttpErrors:undefined,
    requestApiRecovery:()=>{calls++;return new Promise(()=>{});},cancelApiRecovery(){cancelled++;},
  }});
  const result=assert.rejects(api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile',{timeout:1000,retryCount})),e=>e.code==='recovery_status_ambiguous');
  await settle();t.mock.timers.tick(retryCount===0?1000:500);await settle();await result;assert.equal(calls,1);assert.equal(cancelled,1);
  t.mock.timers.tick(30000);await settle();assert.equal(calls,1);
});

for(const retryCount of [0,2])test(`new native buffered slow-401 body timeout cannot alias (retryCount=${retryCount})`,async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const requests=[],cancelled=[];
  // Native has received denial headers but cannot resolve its buffered promise yet.
  const nativeWireResponse={status:401,headers:{},body:new Promise(()=>{})};
  const api=client({fetch:()=>assert.fail('hidden denial must not alias into ordinary Fetch'),native:{
    apiRecoveryHosts:['api.vexguard.app','api2.vexguard.app'],apiRecoveryPreservesHttpErrors:true,
    requestApiRecovery:async(id,url)=>{requests.push([id,url]);await nativeWireResponse.body;return nativeWireResponse;},cancelApiRecovery:id=>cancelled.push(id),
  }});
  const result=assert.rejects(api.withProfileRecoveryTransport(()=>api.rawRequest('/v1/vpn/profile',{timeout:1000,retryCount,accessToken:'fixture'})),e=>e.code==='recovery_status_ambiguous');
  await settle();t.mock.timers.tick(retryCount===0?1000:500);await settle();await result;
  assert.equal(nativeWireResponse.status,401);assert.equal(requests.length,1);assert.equal(requests[0][1],'https://api.vexguard.app/v1/vpn/profile');assert.deepEqual(cancelled,[requests[0][0]]);
  t.mock.timers.tick(120000);await settle();assert.equal(requests.length,1);
});

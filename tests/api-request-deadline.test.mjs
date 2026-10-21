import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { URL as ExpoURL } from 'whatwg-url-minimum';

const config = stripTypeScriptTypes(fs.readFileSync('src/api/config.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/\bexport /g, '');
const source = stripTypeScriptTypes(fs.readFileSync('src/api/client.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
const errors = stripTypeScriptTypes(fs.readFileSync('src/api/error.ts', 'utf8')).replace(/\bexport /g, '');
const fetchPolicy = stripTypeScriptTypes(fs.readFileSync('src/api/apiFetch.ts', 'utf8')).replace(/\bexport /g, '');
const settle = async () => { for (let i=0; i<30; i++) await Promise.resolve(); };
function client(fetch, appInfo = async () => ({}), baseUrl, URLImplementation = URL) {
  return new Function('URL', 'process', 'fetch', 'getAppInfo', 'getOrCreateDeviceId', 'Platform', 'androidExperimentalRoutingEnabled', 'androidProfilePlatform', errors + fetchPolicy + config + source + '; return rawRequest;')(
    URLImplementation, { env: { EXPO_PUBLIC_VEX_API_BASE_URL: baseUrl } }, fetch, appInfo, async () => 'fixture', {OS:'android'}, () => false, () => 'android');
}

test('a stalled GET has one total deadline rather than three full timeouts', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0;
  const raw=client((_url,{signal}) => { calls++; return new Promise((_,reject) => signal.addEventListener('abort',()=>reject(Object.assign(new Error('aborted'),{name:'AbortError'})))); });
  let done=false;
  const result=raw('/v1/vpn/profile',{timeout:1000}).then(()=>assert.fail('expected timeout'),()=>{done=true;});
  await settle(); t.mock.timers.tick(1000); await settle();
  assert.equal(done,true,'the first deadline must settle the caller');
  assert.equal(calls,1,'do not restart a full timeout budget');
  await result;
});

test('stalled native header lookup is bounded and cannot issue a late request', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let release,calls=0,done=false;
  const pending=new Promise(r=>release=r);
  const raw=client(async()=>{calls++;return {ok:true,text:async()=>'ok'};},()=>pending);
  const result=raw('/v1/devices',{timeout:1000}).catch(()=>{done=true;});
  await settle();t.mock.timers.tick(1000);await settle();
  assert.equal(done,true,'native setup must obey the request deadline');
  release({});await settle();assert.equal(calls,0,'expired setup must not start fetch');await result;
});

test('transient failure can retry inside the total budget', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0;
  const raw=client(async()=>++calls===1 ? {ok:false,status:503,text:async()=>'{"message":"temporary"}'} : {ok:true,text:async()=>'recovered'});
  const result=raw('/v1/devices',{timeout:2000});await settle();t.mock.timers.tick(600);await settle();
  assert.equal(await result,'recovered');assert.equal(calls,2);
});

test('response body that ignores abort still cannot hold the caller forever', async t => {
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let done=false;
  const raw=client(async()=>({ok:true,text:()=>new Promise(()=>{})}));
  const result=raw('/v1/devices',{timeout:1000}).catch(()=>{done=true;});
  await settle();t.mock.timers.tick(1000);await settle();assert.equal(done,true);await result;
});

function failure(status, retryAfter, message = 'temporary') {
  return {ok:false,status,headers:{get:() => retryAfter},text:async()=>JSON.stringify({message})};
}

for (const status of [429, 503]) {
  test(`GET respects Retry-After on HTTP ${status}`, async t => {
    t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
    let calls=0;
    const raw=client(async()=>++calls===1 ? failure(status,'2') : {ok:true,text:async()=>'recovered'});
    const result=raw('/v1/vpn/profile',{timeout:5000});await settle();
    t.mock.timers.tick(1999);await settle();assert.equal(calls,1);
    t.mock.timers.tick(1);await settle();assert.equal(await result,'recovered');assert.equal(calls,2);
  });
}

test('HTTP-date Retry-After survives error normalization',async t=>{
  const now=Date.UTC(2026,9,10);
  t.mock.timers.enable({apis:['setTimeout','Date'],now});
  let calls=0;
  const raw=client(async()=>++calls===1 ? failure(503,new Date(now+3000).toUTCString()) : {ok:true,text:async()=>'ok'});
  const result=raw('/v1/vpn/profile',{timeout:5000});await settle();
  t.mock.timers.tick(2999);await settle();assert.equal(calls,1);
  t.mock.timers.tick(1);await settle();assert.equal(await result,'ok');assert.equal(calls,2);
});

test('server wait outside the deadline returns the original status without early retry',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  let calls=0;
  const raw=client(async()=>{calls++;return failure(429,'60','slow down');});
  await assert.rejects(raw('/v1/devices',{timeout:1000}),error=>error.status===429 && error.retryAfterMs===60000 && error.message==='slow down');
  assert.equal(calls,1);t.mock.timers.tick(60000);await settle();assert.equal(calls,1);
});

for(const retryAfter of [null,'invalid','-1','1.5']) {
  test(`invalid or missing Retry-After uses bounded backoff: ${retryAfter}`,async t=>{
    t.mock.timers.enable({apis:['setTimeout','Date'],now:0});let calls=0;
    const raw=client(async()=>++calls===1 ? failure(503,retryAfter) : {ok:true,text:async()=>'ok'});
    const result=raw('/v1/devices',{timeout:2000});await settle();
    t.mock.timers.tick(599);await settle();assert.equal(calls,1);
    t.mock.timers.tick(1);await settle();assert.equal(await result,'ok');
  });
}

for(const message of ['Failed to fetch','Load failed','fetch request has been canceled','connection reset','could not connect']) {
  test(`transient transport error retries: ${message}`,async t=>{
    t.mock.timers.enable({apis:['setTimeout','Date'],now:0});let calls=0;
    const raw=client(async()=>{if(++calls===1)throw new TypeError(message);return {ok:true,text:async()=>'ok'};});
    const result=raw('/v1/devices',{timeout:2000});await settle();t.mock.timers.tick(600);await settle();
    assert.equal(await result,'ok');assert.equal(calls,2);
  });
}

for(const status of [400,401,403,404,409]) {
  test(`HTTP ${status} is never retried even with a transport-like message`,async()=>{
    let calls=0;
    const raw=client(async()=>{calls++;return failure(status,'0','connection reset');});
    await assert.rejects(raw('/v1/devices'),error=>error.status===status);assert.equal(calls,1);
  });
}

test('POST with idempotency key remains a single attempt',async()=>{
  let calls=0;
  const raw=client(async()=>{calls++;return failure(503,'0');});
  await assert.rejects(raw('/v1/devices/register',{method:'POST',idempotencyKey:'fixture-key',body:{}}),error=>error.status===503);
  assert.equal(calls,1);
});

test('retryCount zero disables retry for throttling',async()=>{
  let calls=0;
  const raw=client(async()=>{calls++;return failure(429,'0');});
  await assert.rejects(raw('/v1/devices',{retryCount:0}),error=>error.status===429);assert.equal(calls,1);
});

test('outer deadline retains the machine-readable request_timeout code',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:0});
  const raw=client(()=>new Promise(()=>{}));
  const result=assert.rejects(raw('/v1/devices',{timeout:1000}),error=>error.code==='request_timeout');
  await settle();t.mock.timers.tick(1000);await settle();await result;
});


for (const [body, code, message] of [
  ['{"code":17,"message":" visible "}', undefined, 'visible'],
  ['{"code":" quota ","message":42,"error":" legacy "}', 'quota', 'legacy'],
  ['{"code":"quota","message":"  ","error":"legacy"}', 'quota', 'legacy'],
  ['{"code":"quota","message":null,"error":[]}', 'quota', 'HTTP 400'],
  ['{"code":{},"debug":"inert-private-fixture"}', undefined, 'HTTP 400'],
  ['null', undefined, 'HTTP 400'],
  ['[]', undefined, 'HTTP 400'],
  ['123', undefined, 'HTTP 400'],
  ['true', undefined, 'HTTP 400'],
  ['{"message":"inert-private-fixture"', undefined, 'HTTP 400'],
  ['<html>inert-private-fixture</html>', undefined, 'HTTP 400'],
  ['" legacy string "', undefined, 'legacy string'],
  [' legacy text ', undefined, 'legacy text'],
]) {
  test('error fields are independently narrowed: ' + body, async () => {
    const raw = client(async () => ({ ok: false, status: 400, text: async () => body }));
    await assert.rejects(raw('/v1/devices'), error => error.status === 400 && error.code === code && error.message === message);
  });
}

test('a malformed message cannot discard a maintenance code and trigger session expiry', async () => {
  const raw = client(async () => ({ ok: false, status: 401, text: async () => '{"code":"maintenance","message":42,"error":"temporary"}' }));
  await assert.rejects(raw('/v1/auth/me'), error => error.status === 401 && error.code === 'maintenance');
});


test('development diagnostics never echo the raw error response body', async t => {
  const prior = globalThis.__DEV__;
  globalThis.__DEV__ = true;
  const lines = [];
  t.mock.method(console, 'log', (...parts) => lines.push(parts.join(' ')));
  try {
    const raw = client(async () => ({ ok: false, status: 400, text: async () => '{"message":"public failure","debug":"inert-private-fixture"}' }));
    await assert.rejects(raw('/v1/devices'), error => error.status === 400);
    assert.equal(lines.some(line => line.includes('inert-private-fixture')), false);
  } finally {
    if (prior === undefined) delete globalThis.__DEV__;
    else globalThis.__DEV__ = prior;
  }
});

for (const URLImplementation of [URL, ExpoURL]) {
for (const baseUrl of ['relative/path', 'file:///private/fixture', 'https://user:fixture@example.invalid', 'https://example.invalid?route=other', 'https://example.invalid#fragment', 'http://[invalid']) {
  test(`${URLImplementation === URL ? 'Node' : 'Expo'} URL: invalid API base fails before native setup or fetch: ${baseUrl}`, async () => {
    let setupCalls = 0, requests = 0;
    const raw = client(async () => { requests++; return { ok: true, text: async () => '[]' }; }, async () => { setupCalls++; return {}; }, baseUrl, URLImplementation);
    await assert.rejects(raw('/v1/billing/plans'), error => error.code === 'invalid_api_base_url');
    assert.equal(setupCalls, 0);
    assert.equal(requests, 0);
  });
}

test(`${URLImplementation === URL ? 'Node' : 'Expo'} URL: API base path and query parameters survive shared URL construction`, async () => {
  const requests = [];
  const raw = client(async url => { requests.push(url); return { ok: true, text: async () => '[]' }; }, undefined, 'http://127.0.0.1:45678/gateway///', URLImplementation);
  assert.equal(await raw('/v1/devices?limit=24&cursor=a%2Fb'), '[]');
  assert.deepEqual(requests, ['http://127.0.0.1:45678/gateway/v1/devices?limit=24&cursor=a%2Fb']);
});

}

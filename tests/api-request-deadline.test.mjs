import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const source = stripTypeScriptTypes(fs.readFileSync('src/api/client.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
const errors = stripTypeScriptTypes(fs.readFileSync('src/api/error.ts', 'utf8')).replace(/\bexport /g, '');
const settle = async () => { for (let i=0; i<30; i++) await Promise.resolve(); };
function client(fetch, appInfo = async () => ({})) {
  return new Function('fetch', 'getAppInfo', 'getOrCreateDeviceId', 'Platform', 'androidExperimentalRoutingEnabled', 'androidProfilePlatform', errors + source + '; return rawRequest;')(
    fetch, appInfo, async () => 'fixture', {OS:'android'}, () => false, () => 'android');
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

for(const message of ['Failed to fetch','Load failed','connection reset','could not connect']) {
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

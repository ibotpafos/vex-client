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

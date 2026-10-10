import fs from 'node:fs';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';
const source=stripTypeScriptTypes(fs.readFileSync('src/api/nativeDeviceRegistration.ts','utf8')).replace(/\bexport /g,'');
function registration(){return new Function(source+';return getOrCreateNativeDeviceRegistration;')();}

test('concurrent requests for the same installation share one registration',async()=>{
  const register=registration();let starts=0;
  const start=async()=>{starts++;return {id:'fixture'};};
  const requests=Array.from({length:12},()=>register('token','installation',start));
  assert.equal(new Set(requests).size,1);
  await Promise.all(requests);assert.equal(starts,1);
});

test('completed registration does not resurrect a device missing from the server',async()=>{
  const register=registration();let starts=0;
  const start=async()=>({id:`fixture-${++starts}`});
  assert.deepEqual(await register('token','installation',start),{id:'fixture-1'});
  assert.deepEqual(await register('token','installation',start),{id:'fixture-2'});
});

test('interleaved users and installations keep independent requests in flight',async()=>{
  const register=registration();let release,starts=0;
  const pending=new Promise(resolve=>release=resolve);
  const start=()=>{starts++;return pending;};
  const first=register('user-a','installation-a',start);
  const otherUser=register('user-b','installation-a',start);
  const otherDevice=register('user-a','installation-b',start);
  assert.equal(register('user-a','installation-a',start),first);
  assert.equal(register('user-b','installation-a',start),otherUser);
  assert.equal(register('user-a','installation-b',start),otherDevice);
  await Promise.resolve();assert.equal(starts,3);release({id:'fixture'});
  await Promise.all([first,otherUser,otherDevice]);
});

test('both asynchronous rejection and synchronous native failure release registration',async()=>{
  const register=registration();
  await assert.rejects(register('token','installation',async()=>{throw new Error('network');}),/network/);
  await assert.rejects(register('token','installation',()=>{throw new Error('native');}),/native/);
  assert.deepEqual(await register('token','installation',async()=>({id:'recovered'})),{id:'recovered'});
});

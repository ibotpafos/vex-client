import fs from 'node:fs';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';
const source=stripTypeScriptTypes(fs.readFileSync('src/native/appInfo.ts','utf8')).replace(/^import .*;$/gm,'').replace(/\bexport /g,'');
function identity(store){return new Function('SecureStore','Application','Platform',source+';return {getOrCreateDeviceId,getOrCreateInstallId};')(store,{},{});}
test('concurrent first-launch callers receive one persistent installation identity',async()=>{
 const saved=new Map();let reads=0,writes=0;
 const api=identity({getItemAsync:async key=>{reads++;return saved.get(key)||null;},setItemAsync:async(key,value)=>{writes++;saved.set(key,value);}});
 const ids=await Promise.all(Array.from({length:12},()=>api.getOrCreateDeviceId()));
 assert.equal(new Set(ids).size,1);assert.equal(writes,1);assert.equal(reads,1);
 assert.equal(await api.getOrCreateDeviceId(),ids[0]);assert.equal(reads,1,'stable identity should not cross the native storage bridge for every request');
 const install=await api.getOrCreateInstallId();assert.notEqual(install,ids[0]);
});
test('storage read failure must not overwrite an existing device identity',async()=>{
 let fail=true,writes=0;
 const api=identity({getItemAsync:async()=>{if(fail)throw new Error('locked');return 'existing-device';},setItemAsync:async()=>{writes++;}});
 await assert.rejects(api.getOrCreateDeviceId(),/locked/);assert.equal(writes,0);
 fail=false;assert.equal(await api.getOrCreateDeviceId(),'existing-device');
});
test('persistence failure rejects and can retry without caching an unpersisted identity',async()=>{
 let fail=true;
 const api=identity({getItemAsync:async()=>null,setItemAsync:async()=>{if(fail)throw new Error('write failed');}});
 await assert.rejects(api.getOrCreateInstallId(),/write failed/);
 fail=false;assert.match(await api.getOrCreateInstallId(),/^vexi_/);
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const screen=readFileSync('src/vpn/useVpnConnection.ts','utf8');
assert.doesNotMatch(screen,/lastRegisteredPushDeviceRef/,'failed attempts must not be permanently cached');
assert.match(screen,/startPushRegistrationLoop/);
const { startPushRegistrationLoop }=await import('../src/notifications/pushRegistrationLoop.ts');
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
let timers=[], sent=[], value=null, fail=false, prompts=[];
const loop=startPushRegistrationLoop({
 getRegistration:async allowPrompt=>{prompts.push(allowPrompt);return value;},
 register:async r=>{if(fail)throw Error('offline');sent.push(r.token);},
 schedule:(f,ms)=>{const t={f,ms};timers.push(t);return t;},
 cancel:t=>{timers=timers.filter(x=>x!==t);},
});
const tick=async()=>{const t=timers.shift();assert.ok(t);await t.f();await flush();};
await flush();assert.deepEqual(sent,[]);assert.equal(timers.length,1);
value={provider:'fcm',token:'A'};await tick();assert.deepEqual(sent,['A']);
await tick();assert.deepEqual(sent,['A'],'unchanged token must not be resent');
value={provider:'fcm',token:'B'};fail=true;await tick();assert.deepEqual(sent,['A']);assert.equal(timers[0].ms,5000);
fail=false;await tick();assert.deepEqual(sent,['A','B'],'failed registration must retry');
assert.equal(prompts.filter(Boolean).length,1,'no repeated permission prompts during retry');
loop.stop();assert.equal(timers.length,0);
let release;let late=[];
const stopped=startPushRegistrationLoop({getRegistration:()=>new Promise(r=>{release=r;}),register:async r=>{late.push(r);},schedule:()=>{throw Error('timer after stop');},cancel:()=>{}});
stopped.stop();release({provider:'fcm',token:'late'});await flush();assert.deepEqual(late,[]);
console.log('PUSH_REGISTRATION_LOOP=PASS: denied-to-granted, dedup, rotation, network retry, one prompt, teardown, stale completion');
let backoff=[], pendingTimers=[];
const errors=startPushRegistrationLoop({getRegistration:async()=>{throw Error('token unavailable');},register:async()=>{throw Error('unexpected');},schedule:(f,ms)=>{backoff.push(ms);pendingTimers.push(f);return f;},cancel:()=>{}});
await flush();for(let i=0;i<7;i++){await pendingTimers.shift()();await flush();}
assert.deepEqual(backoff,[5000,10000,20000,40000,60000,60000,60000,60000]);
errors.stop();
let completeRegistration;let scheduledAfterStop=0;
const duringRegister=startPushRegistrationLoop({getRegistration:async()=>({provider:'fcm',token:'pending'}),register:()=>new Promise(r=>{completeRegistration=r;}),schedule:()=>{scheduledAfterStop++;},cancel:()=>{}});
await flush();duringRegister.stop();completeRegistration();await flush();assert.equal(scheduledAfterStop,0);
console.log('PUSH_RETRY_BACKOFF_AND_INFLIGHT_TEARDOWN=PASS');

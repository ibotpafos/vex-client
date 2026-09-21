import assert from 'node:assert/strict';
import { runProfileRequest, ProfileRequestSupersededError } from '../src/vpn/profileRequestQueue.ts';

async function main() {
 let finish;
 const pending = new Promise(r => { finish=r; });
 const calls = [];
 const old = runProfileRequest(async () => { calls.push('old-start'); await pending; calls.push('old-end'); });
 await Promise.resolve();
 const connect = runProfileRequest(async () => { calls.push('connect'); return 'fresh-ip'; });
 let stillCurrent=true;
 const background = runProfileRequest(async () => { calls.push('stale-background'); }, () => stillCurrent, 'background');
 const rejected = assert.rejects(background, ProfileRequestSupersededError);
 stillCurrent=false;
 assert.deepEqual(calls,['old-start']);
 finish(); await old;
 assert.equal(await connect,'fresh-ip'); await rejected;
 assert.deepEqual(calls,['old-start','old-end','connect']);
 await assert.rejects(runProfileRequest(async () => { throw new Error('network'); }), /network/);
 assert.equal(await runProfileRequest(async () => 'recovered'),'recovered');

 let releaseBlocker;
 const blockerGate = new Promise(r => { releaseBlocker = r; });
 const priorityCalls = [];
 const blocker = runProfileRequest(async () => { priorityCalls.push('blocker'); await blockerGate; });
 await Promise.resolve();
 const queuedBackground = runProfileRequest(async () => { priorityCalls.push('background'); return 'background'; }, () => true, 'background');
 const queuedForeground = runProfileRequest(async () => { priorityCalls.push('foreground'); return 'foreground'; });
 releaseBlocker();
 await blocker;
 assert.equal(await queuedForeground, 'foreground');
 assert.equal(await queuedBackground, 'background');
 assert.deepEqual(priorityCalls, ['blocker','foreground','background']);
 console.log('PROFILE_REQUEST_SERIALIZATION_AND_STALE_CANCELLATION=PASS');
}
void main();

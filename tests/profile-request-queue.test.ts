import assert from 'node:assert/strict';
import { runProfileRequest, ProfileRequestSupersededError } from '../src/vpn/profileRequestQueue';

async function main() {
 let finish!: () => void;
 const pending = new Promise<void>(r => { finish=r; });
 const calls: string[] = [];
 const old = runProfileRequest(async () => { calls.push('old-start'); await pending; calls.push('old-end'); });
 await Promise.resolve();
 const connect = runProfileRequest(async () => { calls.push('connect'); return 'fresh-ip'; });
 let stillCurrent=true;
 const background = runProfileRequest(async () => { calls.push('stale-background'); }, () => stillCurrent);
 const rejected = assert.rejects(background, ProfileRequestSupersededError);
 stillCurrent=false;
 assert.deepEqual(calls,['old-start']);
 finish(); await old;
 assert.equal(await connect,'fresh-ip'); await rejected;
 assert.deepEqual(calls,['old-start','old-end','connect']);
 await assert.rejects(runProfileRequest(async () => { throw new Error('network'); }), /network/);
 assert.equal(await runProfileRequest(async () => 'recovered'),'recovered');
 console.log('PROFILE_REQUEST_SERIALIZATION_AND_STALE_CANCELLATION=PASS');
}
void main();

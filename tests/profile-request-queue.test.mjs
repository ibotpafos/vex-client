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

 let releasePrefetch;
 const prefetchGate = new Promise(r => { releasePrefetch = r; });
 const coalescedCalls = [];
 const prefetch = runProfileRequest(async () => {
   coalescedCalls.push('background-prefetch');
   await prefetchGate;
   return 'fresh-profile';
 }, () => true, 'background', 'same-profile');
 await Promise.resolve();
 const joinedForeground = runProfileRequest(async () => {
   coalescedCalls.push('foreground-network');
   return 'duplicate-profile';
 }, () => true, 'foreground', 'same-profile');
 releasePrefetch();
 assert.equal(await prefetch, 'fresh-profile');
 assert.equal(await joinedForeground, 'fresh-profile');
 assert.deepEqual(coalescedCalls, ['background-prefetch']);

 let releaseDifferentPrefetch;
 const differentPrefetchGate = new Promise(r => { releaseDifferentPrefetch = r; });
 const differentCalls = [];
 const differentPrefetch = runProfileRequest(async () => {
   differentCalls.push('background-revalidate');
   await differentPrefetchGate;
   return 'revalidated-profile';
 }, () => true, 'background', 'revalidate-profile');
 await Promise.resolve();
 const freshForeground = runProfileRequest(async () => {
   differentCalls.push('foreground-fresh');
   return 'fresh-profile';
 }, () => true, 'foreground', 'fresh-profile');
 releaseDifferentPrefetch();
 await differentPrefetch;
 assert.equal(await freshForeground, 'fresh-profile');
 assert.deepEqual(differentCalls, ['background-revalidate','foreground-fresh']);

 let releaseFailedPrefetch;
 const failedPrefetchGate = new Promise(r => { releaseFailedPrefetch = r; });
 const retryCalls = [];
 const failedPrefetch = runProfileRequest(async () => {
   retryCalls.push('background-failed');
   await failedPrefetchGate;
   throw new Error('prefetch failed');
 }, () => true, 'background', 'retry-profile');
 const failedPrefetchRejected = assert.rejects(failedPrefetch, /prefetch failed/);
 await Promise.resolve();
 const retriedForeground = runProfileRequest(async () => {
   retryCalls.push('foreground-retry');
   return 'foreground-profile';
 }, () => true, 'foreground', 'retry-profile');
 releaseFailedPrefetch();
 await failedPrefetchRejected;
 assert.equal(await retriedForeground, 'foreground-profile');
 assert.deepEqual(retryCalls, ['background-failed','foreground-retry']);
 console.log('PROFILE_REQUEST_SERIALIZATION_AND_STALE_CANCELLATION=PASS');
}
void main();

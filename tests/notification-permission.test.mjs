import assert from 'node:assert/strict';
import { createNotificationPermissionGate } from '../src/notifications/notificationPermission.ts';
let state = { granted: false, status: 'denied', canAskAgain: true };
let prompts = 0;
let resolveRequest;
const gate = createNotificationPermissionGate({
  get: async () => state,
  request: async () => { prompts++; return new Promise(resolve => { resolveRequest = resolve; }); },
});
assert.equal(await gate(true), false);
assert.equal(prompts, 0, 'Prior denial must not trigger another automatic prompt');
state = { granted: false, status: 'undetermined', canAskAgain: true };
assert.equal(await gate(false), false);
assert.equal(prompts, 0);
const first = gate(true); const second = gate(true);
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(prompts, 1, 'Concurrent callers share one permission dialog');
resolveRequest({ granted: false });
assert.deepEqual(await Promise.all([first, second]), [false, false]);
assert.equal(await gate(true), false, 'Stale undetermined reads must not repeat a completed prompt');
assert.equal(prompts, 1);
state = { granted: true, status: 'granted', canAskAgain: true };
assert.equal(await gate(false), true, 'Settings grant must be read fresh');
assert.equal(prompts, 1);
let errors = 0;
const failed = createNotificationPermissionGate({ get: async () => ({ granted: false, status: 'undetermined', canAskAgain: true }), request: async () => { errors++; throw Error('fixture'); } });
await assert.rejects(failed(true), /fixture/);
assert.equal(await failed(true), false, 'Do not spam a failing OS dialog within one process');
assert.equal(errors, 1);
console.log('NOTIFICATION_PERMISSION_GATE=PASS: denial, single-flight, stale reads, settings grant, failure');

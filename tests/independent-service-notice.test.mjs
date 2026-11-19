import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import {
  createIndependentStatusStore, independentServiceStatusURL, initialIndependentStatus,
  parseIndependentServiceStatus, readIndependentServiceStatus, updateIndependentStatus,
  withServiceStatusDeadline,
} from '../src/status/independent-service-status.ts';
import { createRemoteConfigStore } from '../src/status/remote-config-store.ts';
import { projectServiceNotice } from '../src/status/service-notice-state.ts';

const base = Date.now();
function status(mode = 'maintenance', at = base) {
  return {
    schema: 'vex.service-status.v1', status: mode, title: mode === 'maintenance' ? 'Идут технические работы' : 'Сервис работает',
    message: 'Восстанавливаем работу сервиса.', checked_at: new Date(at).toISOString(),
    expires_at: new Date(at + 45_000).toISOString(),
    ...(mode === 'maintenance' ? { incident_id: 'public_0123456789abcdef', started_at: new Date(base - 1_000).toISOString() } : {}),
  };
}
const tick = () => new Promise((resolve) => setImmediate(resolve));

test('native independent status validates schema/freshness and only fresh operational evidence clears its warning', () => {
  const known = updateIndependentStatus(initialIndependentStatus, status(), base);
  assert.equal(known.report.status, 'maintenance');
  assert.equal(updateIndependentStatus(known, status(), base), known);
  assert.equal(updateIndependentStatus(known, status('operational'), base).report.status, 'maintenance');
  assert.equal(updateIndependentStatus(known, { ...status(), message: 'Changed at equal clock' }, base).report.message, known.report.message);
  for (const invalid of [null, {}, { ...status(), schema: 'other' }, { ...status(), status: false }, status('operational', base - 120_000), { ...status(), expires_at: new Date(base - 1).toISOString() }]) {
    const next = updateIndependentStatus(known, invalid, base);
    assert.equal(next.report.status, 'maintenance');
    assert.equal(next.unavailable, true);
  }
  const unknown = updateIndependentStatus(known, status('unknown', base + 1_000), base + 1_000);
  assert.equal(unknown.report.status, 'maintenance');
  assert.equal(unknown.unavailable, true);
  assert.equal(updateIndependentStatus(unknown, status('operational', base + 500), base + 1_000).report.status, 'maintenance');
  const recovered = updateIndependentStatus(unknown, status('operational', base + 2_000), base + 2_000);
  assert.equal(recovered.report.status, 'operational');
  assert.equal(recovered.unavailable, false);
  assert.equal(parseIndependentServiceStatus({ ...status(), checked_at: '2026-02-31T12:00:00Z' }, Date.parse('2026-03-03T12:00:00Z')), null);
});

test('API/manual warnings keep priority; failed/stale observer reads retain their warning; API health tolerates absent staged feed', () => {
  const external = updateIndependentStatus(initialIndependentStatus, status(), base);
  const healthyAPI = { config: { platform: 'android' }, unavailable: false };
  const failedAPI = { config: null, unavailable: true };
  assert.equal(projectServiceNotice(failedAPI, external, base).title, 'Идут технические работы');
  const manual = { config: { platform: 'android', incidentBanner: 'Ручное сообщение' }, unavailable: false };
  assert.equal(projectServiceNotice(manual, external, base).message, 'Ручное сообщение');
  const recovered = updateIndependentStatus(external, status('operational', base + 1_000), base + 1_000);
  assert.equal(projectServiceNotice({ ...manual, unavailable: true }, recovered, base + 1_000).message, 'Ручное сообщение');
  assert.equal(projectServiceNotice({ ...manual, unavailable: true }, recovered, base + 1_000).unavailable, true);
  const stale = updateIndependentStatus(external, null, base);
  assert.equal(projectServiceNotice(healthyAPI, stale, base).unavailable, true);
  assert.equal(projectServiceNotice(healthyAPI, recovered, base + 1_000), null);
  assert.equal(projectServiceNotice(healthyAPI, { ...initialIndependentStatus, unavailable: true }, base), null);
  const unknown = projectServiceNotice(failedAPI, { ...initialIndependentStatus, unavailable: true }, base);
  assert.equal(unknown.title, 'Статус VPN уточняется');
  assert.equal(unknown.message, undefined);
});

test('independent warning is visible while the API is still pending; Home/Settings share polls and foreground reads', async () => {
  let foreground;
  const timers = new Set();
  let removed = 0;
  let reads = 0;
  let release;
  const external = createIndependentStatusStore(async () => { reads++; return status(); }, {
    foreground(callback) { foreground = callback; return () => { removed++; }; },
    schedule(callback, delay) { assert.equal(delay, 15_000); timers.add(callback); return () => timers.delete(callback); },
  });
  const api = createRemoteConfigStore(() => new Promise((resolve) => { release = resolve; }), {
    foreground() { return () => {}; }, schedule() { return () => {}; },
  });
  const pendingAPI = api.refresh();
  const sameListener = () => {};
  const home = external.subscribe(sameListener);
  const settings = external.subscribe(sameListener);
  foreground();
  const pendingExternal = external.refresh();
  await tick();
  assert.equal(reads, 1);
  assert.equal(projectServiceNotice(api.getSnapshot(), external.getSnapshot()).title, 'Идут технические работы');
  await pendingExternal;
  assert.equal(timers.size, 1);
  release({ platform: 'android', incidentBanner: 'Сообщение API' });
  await pendingAPI;
  assert.equal(projectServiceNotice(api.getSnapshot(), external.getSnapshot()).message, 'Сообщение API');
  home();
  assert.equal(removed, 0);
  settings();
  assert.equal(removed, 1);
  assert.equal(timers.size, 0);
});

test('external fetch never uses API/session credentials and rejects redirects, oversized bodies and hangs', async () => {
  let request;
  let target;
  const result = await readIndependentServiceStatus(async (url, init) => {
    target = url; request = init;
    return new Response(JSON.stringify(status()), { headers: { 'content-type': 'application/json' } });
  });
  assert.equal(result.schema, 'vex.service-status.v1');
  assert.equal(target, independentServiceStatusURL);
  assert.equal(request.credentials, 'omit');
  assert.equal(request.redirect, 'error');
  assert.deepEqual(request.headers, { Accept: 'application/json' });
  assert.equal(request.body, undefined);
  let signal;
  await assert.rejects(withServiceStatusDeadline((value) => { signal = value; return new Promise(() => {}); }, 5), /deadline/);
  assert.equal(signal.aborted, true);
  for (const response of [
    new Response('{}', { status: 404 }), new Response('{}', { headers: { 'content-type': 'text/html' } }),
    new Response('{}', { headers: { 'content-type': 'application/json', 'content-length': '65537' } }),
    { ok: true, redirected: true, url: 'https://other.invalid/', headers: new Headers(), text: async () => '{}' },
  ]) await assert.rejects(readIndependentServiceStatus(async () => response));
  const source = readFileSync(new URL('../src/status/independent-service-status.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /vexApi|accessToken|Authorization|Cookie/);
  const hook = readFileSync(new URL('../src/status/use-service-notice.ts', import.meta.url), 'utf8');
  assert.match(hook, /const independentStore = createIndependentStatusStore\(\(\) => readIndependentServiceStatus\(\)/);
});

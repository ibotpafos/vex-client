import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import { createRemoteConfigStore } from '../src/status/remote-config-store.ts';

const config = (incidentBanner) => ({ platform: 'android', channel: 'stable', incidentBanner });
function fixture(load) {
  let foreground;
  const timers = new Set();
  let removed = 0;
  const store = createRemoteConfigStore(load, {
    foreground(callback) { foreground = callback; return () => { removed++; }; },
    schedule(callback) { timers.add(callback); return () => timers.delete(callback); },
  });
  return { store, timers, foreground: () => foreground(), removed: () => removed };
}

test('Home and Settings share an in-flight read, one timer and foreground listener', async () => {
  let reads = 0;
  let resolve;
  const f = fixture(() => { reads++; return new Promise((done) => { resolve = done; }); });
  const home = f.store.subscribe(() => {});
  const settings = f.store.subscribe(() => {});
  f.foreground();
  const pending = f.store.refresh();
  await Promise.resolve();
  assert.equal(reads, 1);
  resolve(config('Технические работы'));
  await pending;
  assert.equal(f.timers.size, 1);
  f.foreground();
  const next = f.store.refresh();
  await Promise.resolve();
  assert.equal(reads, 2);
  resolve(config());
  await next;
  assert.equal(f.store.getSnapshot().config.incidentBanner, undefined);
  home();
  assert.equal(f.removed(), 0);
  settings();
  assert.equal(f.removed(), 1);
  assert.equal(f.timers.size, 0);
});

test('network error retains known warning; fresh response confirms recovery', async () => {
  let result = config('Работы');
  const f = fixture(async () => { if (result instanceof Error) throw result; return result; });
  await f.store.refresh();
  result = new Error('offline');
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().config.incidentBanner, 'Работы');
  assert.equal(f.store.getSnapshot().unavailable, true);
  result = config();
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().config.incidentBanner, undefined);
  assert.equal(f.store.getSnapshot().unavailable, false);
});

test('first-load failure is unknown and independent stores isolate old sessions', async () => {
  const offline = fixture(async () => { throw new Error('offline'); });
  await offline.store.refresh();
  assert.deepEqual(offline.store.getSnapshot(), { config: null, unavailable: true });
  const fresh = fixture(async () => config());
  assert.deepEqual(fresh.store.getSnapshot(), { config: null, unavailable: false });
});

test('both screens use the accessible shared notice without VPN actions', () => {
  for (const screen of ['home-screen.tsx', 'settings-screen.tsx']) {
    const source = readFileSync(new URL(`../src/screens/${screen}`, import.meta.url), 'utf8');
    assert.match(source, /<ServiceNotice \/>/);
  }
  const notice = readFileSync(new URL('../src/components/service-notice.tsx', import.meta.url), 'utf8');
  assert.match(notice, /accessibilityRole="alert" accessibilityLiveRegion="polite"/);
  assert.match(notice, /восстановление пока не подтверждено/);
  assert.doesNotMatch(notice, /handlePowerPress|disconnect|connectVpn/);
});


test('successful config with failed incident read retains warning while applying other fields; fresh recovery clears', async () => {
  let response = { platform: 'android', incidentBanner: 'Технические работы', recommendedBuild: 100 };
  const api = {};
  const source = ts.transpileModule(readFileSync(new URL('../src/api/updates.ts', import.meta.url), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const dependencies = {
    '@/native/appInfo': { VEX_API_CLIENT_VERSION: 'fixture-api', VEX_CONFIG_SCHEMA_VERSION: 1 },
    './client': { jsonRequest: async () => response },
    './updatePreflight': {},
  };
  vm.runInNewContext(source, { exports: api, require(name) {
    assert.ok(Object.hasOwn(dependencies, name), `unexpected import ${name}`);
    return dependencies[name];
  } });
  const f = fixture(() => api.appRemoteConfig({ platform: 'android', appVersion: '1.0.0', buildNumber: 100 }));
  await f.store.refresh();
  response = {
    platform: 'android', incidentBannerUnavailable: true, recommendedBuild: 101,
    recommendedVersion: '1.0.1', routingPolicyVersion: 'policy-2',
    featureFlags: { available: true }, accountFeatureFlags: { enabled: true },
  };
  await f.store.refresh();
  const snapshot = f.store.getSnapshot();
  assert.equal(snapshot.unavailable, true);
  assert.equal(snapshot.config.incidentBanner, 'Технические работы');
  assert.equal(snapshot.config.incidentBannerUnavailable, true);
  assert.equal(snapshot.config.recommendedBuild, 101);
  assert.equal(snapshot.config.recommendedVersion, '1.0.1');
  assert.equal(snapshot.config.routingPolicyVersion, 'policy-2');
  assert.equal(snapshot.config.featureFlags.available, true);
  assert.equal(snapshot.config.accountFeatureFlags.enabled, true);
  response = { platform: 'android', recommendedBuild: 102 };
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().config.incidentBanner, undefined);
  assert.equal(f.store.getSnapshot().unavailable, false);
  assert.equal(f.store.getSnapshot().config.recommendedBuild, 102);
});

test('first partial incident failure is unknown and preserves an available manual notice', async () => {
  let response = { ...config(), incidentBannerUnavailable: true };
  const f = fixture(async () => response);
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().unavailable, true);
  assert.equal(f.store.getSnapshot().config.incidentBanner, undefined);
  response = { ...config('Плановые работы'), incidentBannerUnavailable: true };
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().unavailable, true);
  assert.equal(f.store.getSnapshot().config.incidentBanner, 'Плановые работы');
});

test('malformed unavailable marker cannot clear a known warning', async () => {
  let result = config('Работы');
  const f = fixture(async () => result);
  await f.store.refresh();
  for (const invalid of ['true', null]) {
    result = { ...config(), incidentBannerUnavailable: invalid };
    await f.store.refresh();
    assert.equal(f.store.getSnapshot().config.incidentBanner, 'Работы');
    assert.equal(f.store.getSnapshot().unavailable, true);
  }
  result = { ...config(), incidentBannerUnavailable: false };
  await f.store.refresh();
  assert.equal(f.store.getSnapshot().config.incidentBanner, undefined);
  assert.equal(f.store.getSnapshot().unavailable, false);
});

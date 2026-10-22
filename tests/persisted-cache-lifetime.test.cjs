const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const test = require('node:test');
const root = path.resolve(__dirname, '..');
const hotKey = 'vex.vpn.hot_profiles.v1';
const tick = () => new Promise(resolve => setImmediate(resolve));
function gate() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }

function harness(hooks = {}) {
  const values = new Map(), calls = [], cache = new Map();
  const webValues = new Map();
  const localStorage = {
    getItem: key => webValues.get(key) ?? null,
    setItem: (key, value) => { webValues.set(key, value); },
    removeItem: key => { hooks.remove?.(key); webValues.delete(key); },
  };
  const native = {
    async getItemAsync(key) { const value = values.get(key) ?? null; calls.push(['get', key]); await hooks.get?.(key); return value; },
    async setItemAsync(key, value) { calls.push(['set', key]); await hooks.set?.(key, value); values.set(key, value); },
    async deleteItemAsync(key) { calls.push(['delete', key]); await hooks.delete?.(key); values.delete(key); },
  };
  function load(relative) {
    const filename = path.resolve(root, relative);
    if (cache.has(filename)) return cache.get(filename);
    const exports = {}; cache.set(filename, exports);
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
    const requireForTest = name => {
      if (name === 'expo-secure-store') return native;
      if (name === 'react-native') return { Platform: { OS: hooks.platform ?? 'android' } };
      if (name.startsWith('@/')) return load('src/' + name.slice(2) + '.ts');
      if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(filename), name + '.ts')));
      return require(name);
    };
    vm.runInNewContext(compiled, { exports, require: requireForTest, Date, Map, Set, Promise, JSON, Object, Number, console, localStorage }, { filename });
    return exports;
  }
  return { values, webValues, calls, load };
}
const profile = id => ({ config: 'Address = 10.0.0.2/32', device: { id }, locationId: id, routingMode: 'full_tunnel', source: 'api' });

for (const [name, module, save, key, a, b] of [
  ['hot profiles', 'src/vpn/hotProfileCache.ts', 'saveHotVpnProfile', hotKey, ['owner', 'de', profile('de')], ['owner', 'fi', profile('fi')]],
  ['entitlement', 'src/vpn/vpnQueryCache.ts', 'saveCachedEntitlement', 'vex.entitlement.v1', ['owner-a', { active: true, vpnAccess: true }], ['owner-b', { active: true, vpnAccess: true }]],
  ['billing', 'src/api/billingSummaryCache.ts', 'saveCachedBillingSummary', 'vex.billing.summary.v1', ['owner-a', { title: 'A', subtitle: 'fixture', plans: [] }], ['owner-b', { title: 'B', subtitle: 'fixture', plans: [] }]],
]) {
  test(`parallel ${name} saves retain both independent records`, async () => {
    const h = harness(), api = h.load(module);
    await Promise.all([api[save](...a), api[save](...b)]);
    assert.equal(Object.keys(JSON.parse(h.values.get(key))).length, 2);
  });
}

for (const clear of ['clearHotVpnProfiles', 'clearSensitiveStorageHistory']) {
  test(`${clear} waits for an accepted profile write and cannot be undone by it`, async () => {
    const started = gate(), release = gate();
    const h = harness({ set: async key => { if (key === hotKey) { started.resolve(); await release.promise; } } });
    const hot = h.load('src/vpn/hotProfileCache.ts');
    const storage = h.load('src/native/secureStore.ts');
    const saving = hot.saveHotVpnProfile('owner', 'de', profile('de'));
    await started.promise;
    const clearing = (clear === 'clearHotVpnProfiles' ? hot : storage)[clear]();
    await tick(); release.resolve();
    await Promise.all([saving, clearing]);
    assert.equal(h.values.has(hotKey), false);
  });
}

test('an old invalid-record cleanup cannot remove a newer location save', async () => {
  const started = gate(), release = gate(); let reads = 0;
  const h = harness({ get: async key => { if (key === hotKey && ++reads === 1) { started.resolve(); await release.promise; } } });
  const hot = h.load('src/vpn/hotProfileCache.ts');
  h.values.set(hotKey, JSON.stringify({ 'owner:native:de:full_tunnel': { schemaVersion: 1, userId: 'owner', locationId: 'de' } }));
  const loading = hot.loadHotVpnProfile('owner', 'de', 'full_tunnel');
  await started.promise;
  const saving = hot.saveHotVpnProfile('owner', 'fi', profile('fi'));
  await tick(); release.resolve();
  await Promise.all([loading, saving]);
  assert.equal(Object.values(JSON.parse(h.values.get(hotKey) ?? '{}')).some(record => record.locationId === 'fi'), true);
});

test('a late hydration cannot republish an abandoned session into Query cache', async () => {
  const started = gate(), release = gate(); let current = true;
  const h = harness({ get: async key => { if (key === hotKey) { started.resolve(); await release.promise; } } });
  const hot = h.load('src/vpn/hotProfileCache.ts'), writes = [];
  h.values.set(hotKey, JSON.stringify({ 'owner:native:de:full_tunnel': { schemaVersion: 2, userId: 'owner', runtimeKey: 'native', locationId: 'de', profile: profile('de'), savedAtMs: Date.now() } }));
  const pending = hot.hydrateHotVpnProfilesToQueryCache('owner', 'fixture-token', { setQueryData: (...args) => writes.push(args) }, Date.now(), () => current);
  await started.promise; current = false; release.resolve();
  await pending;
  assert.equal(writes.length, 0);
});

test('an unreadable existing cache is never overwritten as an empty object', async () => {
  let failing = true;
  const h = harness({ get: async () => { if (failing) throw new Error('fixture read failed'); } });
  const hot = h.load('src/vpn/hotProfileCache.ts');
  const existing = JSON.stringify({ kept: { userId: 'other-owner' } });
  h.values.set(hotKey, existing);
  await assert.rejects(hot.saveHotVpnProfile('owner', 'de', profile('de')), /fixture read failed/);
  assert.equal(h.values.get(hotKey), existing);
  assert.equal(h.calls.some(([op]) => op === 'set' || op === 'delete'), false);
  failing = false;
  await hot.saveHotVpnProfile('owner', 'fi', profile('fi'));
  assert.equal(Object.keys(JSON.parse(h.values.get(hotKey))).length, 2);
});

test('a failed write releases the key queue and unrelated keys remain independent', async () => {
  const started = gate(), release = gate(); let failing = true;
  const h = harness({ set: async key => {
    if (key === hotKey && failing) { started.resolve(); await release.promise; throw new Error('fixture write failed'); }
  } });
  const hot = h.load('src/vpn/hotProfileCache.ts'), storage = h.load('src/native/secureStore.ts');
  const saving = hot.saveHotVpnProfile('owner', 'de', profile('de'));
  const rejected = assert.rejects(saving, /fixture write failed/);
  await started.promise;
  await storage.setItemAsync('unrelated.fixture', 'accepted');
  assert.equal(h.values.get('unrelated.fixture'), 'accepted');
  release.resolve(); await rejected;
  failing = false;
  await hot.saveHotVpnProfile('owner', 'fi', profile('fi'));
  assert.equal(Object.values(JSON.parse(h.values.get(hotKey)))[0].locationId, 'fi');
});

test('valid legacy records and missing cache reads never cause storage writes', async () => {
  const h = harness(), hot = h.load('src/vpn/hotProfileCache.ts');
  assert.equal(await hot.loadHotVpnProfile('owner', 'de', 'full_tunnel'), null);
  assert.equal(h.calls.filter(([op]) => op !== 'get').length, 0);
  await hot.saveHotVpnProfile('owner', 'de', profile('de'));
  const bytes = h.values.get(hotKey); h.calls.length = 0;
  assert.equal((await hot.loadHotVpnProfile('owner', 'de', 'full_tunnel')).profile.config, profile('de').config);
  assert.equal(h.values.get(hotKey), bytes);
  assert.equal(h.calls.filter(([op]) => op !== 'get').length, 0);
});

test('hydration stops between profile and entitlement publication when the owner changes synchronously', async () => {
  const h = harness(), hot = h.load('src/vpn/hotProfileCache.ts'); let current = true;
  await hot.saveHotVpnProfile('owner', 'de', { ...profile('de'), entitlement: { active: true, vpnAccess: true } });
  await hot.saveHotVpnProfile('owner', 'fi', profile('fi'));
  const writes = [];
  const result = await hot.hydrateHotVpnProfilesToQueryCache('owner', 'fixture-token', {
    setQueryData: (...args) => { writes.push(args); current = false; },
  }, Date.now(), () => current);
  assert.equal(writes.length, 1);
  assert.equal(writes[0][0][0], 'vpn-profile');
  assert.equal(result.length, 0);
});

for (const [label, mutate, clock] of [
  ['infinite timestamp', r => { r.savedAtMs = Infinity; }],
  ['NaN timestamp', r => { r.savedAtMs = NaN; }],
  ['negative timestamp', r => { r.savedAtMs = -1; }],
  ['future timestamp', r => { r.savedAtMs = 1001; }],
  ['NaN clock', () => {}, NaN],
  ['infinite clock', () => {}, Infinity],
  ['numeric location', r => { r.locationId = 42; }],
  ['object configuration', r => { r.profile.config = {}; }],
  ['blank configuration', r => { r.profile.config = '  '; }],
]) {
  test(`both profile validators reject ${label} consistently without throwing`, () => {
    const core = harness().load('src/vpn/hotProfileCacheCore.ts');
    const record = { schemaVersion: 2, userId: 'owner', runtimeKey: 'native', locationId: 'de', profile: profile('de'), savedAtMs: 1000 };
    mutate(record);
    const now = clock === undefined ? 1000 : clock;
    assert.equal(core.isUsableHotVpnProfileRecord(record, 'owner', 'de', 'native', now), false);
    assert.equal(typeof core.hotVpnProfileRejectionReason(record, 'owner', 'de', 'native', now), 'string');
  });
}

test('profile lifetime retains the inclusive 24-hour boundary and legacy optional fields', () => {
  const core = harness().load('src/vpn/hotProfileCacheCore.ts');
  const record = { schemaVersion: 2, userId: 'owner', runtimeKey: 'native', locationId: 'de', profile: profile('de'), savedAtMs: 1000 };
  for (const age of [0, core.hotVpnProfileTtlMs]) {
    assert.equal(core.isUsableHotVpnProfileRecord(record, 'owner', 'de', 'native', 1000 + age), true);
    assert.equal(core.hotVpnProfileRejectionReason(record, 'owner', 'de', 'native', 1000 + age), null);
  }
  assert.equal(core.hotVpnProfileRejectionReason(record, 'owner', 'de', 'native', 1001 + core.hotVpnProfileTtlMs), 'expired');
});

test('web logout removes legacy and memory copies while preserving installation and account identity', async () => {
  const h = harness({ platform: 'web' }), store = h.load('src/native/secureStore.ts');
  const sessionKeys = ['vex.auth.session.v1', 'vex.auth.session.history.v1'];
  for (const key of sessionKeys) h.webValues.set(key, 'legacy-session');
  assert.equal(await store.getItemAsync(sessionKeys[0]), 'legacy-session');
  assert.equal(h.webValues.has(sessionKeys[0]), false);
  await store.setItemAsync('vex.app.install_id.v1', 'fixture-install');
  await store.setItemAsync('vex.vpn.account_keys.v1.fixture', 'fixture-key');
  await store.clearSensitiveStorageHistory();
  for (const key of sessionKeys) {
    assert.equal(h.webValues.has(key), false);
    assert.equal(await store.getItemAsync(key), null);
  }
  assert.equal(await store.getItemAsync('vex.app.install_id.v1'), 'fixture-install');
  assert.equal(await store.getItemAsync('vex.vpn.account_keys.v1.fixture'), 'fixture-key');
});

for (const key of ['vex.auth.session.v1', 'vex.auth.session.history.v1']) {
  test(`web deletion failure for ${key} remains visible and retryable`, async () => {
    let blocked = false;
    const h = harness({ platform: 'web', remove: name => { if (blocked && name === key) throw new Error('fixture removal failed'); } });
    const store = h.load('src/native/secureStore.ts');
    await store.setItemAsync(key, 'memory-session');
    h.webValues.set(key, 'legacy-session'); blocked = true;
    await assert.rejects(store.clearSensitiveStorageHistory(), /fixture removal failed/);
    assert.equal(h.webValues.get(key), 'legacy-session');
    blocked = false;
    await store.clearSensitiveStorageHistory();
    assert.equal(await store.getItemAsync(key), null);
    assert.equal(h.webValues.has(key), false);
  });
}

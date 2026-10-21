const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const test = require('node:test');
const { QueryClient, isCancelledError } = require('@tanstack/react-query');

const root = path.resolve(process.env.VEX_OWNED_CACHE_SOURCE_ROOT || path.join(__dirname, '..'));
const names = ['persistedEntitlement', 'persistedLocations', 'persistedDevices', 'entitlementData', 'entitlementError',
  'locationsData', 'locationsRefreshError', 'isLocationsRefreshing', 'devicesData', 'deviceUsageSnapshot'];
const setters = names.map(name => `set${name[0].toUpperCase()}${name.slice(1)}`);
const tick = () => new Promise(resolve => setImmediate(resolve));
const gate = () => { let resolve, reject; const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; }); return { promise, resolve, reject }; };

// Execute the actual snapshot declarations, query callback, cache-load/hydrate/
// save and entitlement effects. UI/native work is outside this isolated slice.
function snapshotSource() {
  const file = path.join(root, 'src/vpn/useVpnConnection.ts');
  const source = fs.readFileSync(file, 'utf8'), tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const hook = tree.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === 'useVpnConnection');
  assert.ok(hook);
  const wanted = new Set([...names, ...setters, 'accessToken', 'cacheUserId', 'cacheSessionRef', 'fetchEntitlement', 'entitlementQueryKey']);
  const statements = hook.body.statements.filter(node => {
    if (ts.isVariableStatement(node)) return node.declarationList.declarations.some(d => {
      const declared = ts.isArrayBindingPattern(d.name) ? d.name.elements.map(x => x.name?.text) : [d.name.text];
      return declared.some(name => wanted.has(name));
    });
    return ts.isExpressionStatement(node) && ts.isCallExpression(node.expression) && node.expression.expression.getText(tree) === 'useEffect'
      && /loadCachedEntitlement|queryClient\.setQueryData|saveCachedEntitlement|saveCachedVpnLocations|saveCachedVpnDevices|setEntitlementData/.test(node.getText(tree));
  });
  const projected = `function snapshots(session, isCurrentSessionOperation) {\n${statements.map(n => n.getText(tree)).join('\n')}\nreturn { ${[...names, ...setters].join(',')} };\n}`;
  return ts.transpileModule(projected, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
}

function reactRuntime() {
  const slots = [], effects = [], stateUpdates = []; let cursor = 0, deferred = false;
  const same = (a, b) => a && b && a.length === b.length && a.every((x, i) => Object.is(x, b[i]));
  const react = {
    useState(initial) {
      const index = cursor++;
      if (!slots[index]) slots[index] = { value: typeof initial === 'function' ? initial() : initial };
      const set = update => {
        const apply = () => { slots[index].value = typeof update === 'function' ? update(slots[index].value) : update; };
        if (deferred) stateUpdates.push(apply); else apply();
      };
      return [slots[index].value, set];
    },
    useRef(initial) { const index = cursor++; slots[index] ??= { current: initial }; return slots[index]; },
    useMemo(create, dependencies) {
      const index = cursor++;
      if (!slots[index] || !same(slots[index].dependencies, dependencies)) slots[index] = { value: create(), dependencies };
      return slots[index].value;
    },
    useCallback(callback, dependencies) { return react.useMemo(() => callback, dependencies); },
    useEffect(callback, dependencies) {
      const index = cursor++;
      if (!slots[index] || !same(slots[index].dependencies, dependencies)) {
        const prior = slots[index]; slots[index] = { dependencies, cleanup: prior?.cleanup };
        effects.push(() => { prior?.cleanup?.(); slots[index].cleanup = callback(); });
      }
    },
  };
  return { react, begin: () => { cursor = 0; effects.length = 0; }, commit: () => effects.splice(0).forEach(fn => fn()),
    deferState: () => { deferred = true; }, flushState: () => { deferred = false; stateUpdates.splice(0).forEach(fn => fn()); },
    cleanup: () => slots.forEach(slot => slot?.cleanup?.()) };
}

function load(file, dependencies) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  new Function('require', 'exports', code)(name => { assert.ok(Object.hasOwn(dependencies, name), name); return dependencies[name]; }, exports);
  return exports;
}

function harness({ api, cached } = {}) {
  const runtime = reactRuntime(), requests = [], writes = [], query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const ownedPath = 'src/hooks/useOwnedState.ts';
  const owned = fs.existsSync(path.join(root, ownedPath)) ? load(ownedPath, { react: runtime.react }) : {};
  const policy = load('src/vpn/vpnQueryCachePolicy.ts', {}), errors = load('src/api/error.ts', {});
  let active = { user: 'A', revision: 1 };
  const guards = new Map();
  const dependencies = { ...runtime.react, ...owned, ...policy, ...errors, isCancelledError, queryClient: query,
    customerRealtime: { connected: true, revision: 0 }, entitlementRefreshMs: 60000,
    entitlement: async (token, signal) => { requests.push(token); return api ? api(token, signal) : { active: true, vpnAccess: true, displayName: token }; },
    loadCachedEntitlement: async user => cached?.entitlement?.(user) ?? null,
    loadCachedVpnLocations: async user => cached?.locations?.(user) ?? null,
    loadCachedVpnDevices: async user => cached?.devices?.(user) ?? null,
    saveCachedEntitlement: async (user, value) => { writes.push({ kind: 'entitlement', user, value }); },
    saveCachedVpnLocations: async (user, value) => { writes.push({ kind: 'locations', user, value }); },
    saveCachedVpnDevices: async (user, value) => { writes.push({ kind: 'devices', user, value }); },
  };
  const snapshots = new Function(...Object.keys(dependencies), snapshotSource() + ';return snapshots;')(...Object.values(dependencies));
  function render(user = active.user, token = `token-${user}`) {
    const revision = active.revision, key = `${user}:${revision}`;
    if (!guards.has(key)) guards.set(key, () => active.revision === revision && active.user === user);
    runtime.begin(); return snapshots({ user: { id: user }, accessToken: token }, guards.get(key));
  }
  return { render, commit: runtime.commit, deferState: runtime.deferState, flushState: runtime.flushState, query, requests, writes, change: user => { active = { user, revision: active.revision + 1 }; query.clear(); },
    close: () => { runtime.cleanup(); query.clear(); } };
}

const fixtures = {
  persistedEntitlement: { active: true, vpnAccess: true, displayName: 'account-A' },
  persistedLocations: [{ id: 'location-A' }], persistedDevices: [{ id: 'device-A' }],
  entitlementData: { active: true, vpnAccess: true, displayName: 'account-A' }, entitlementError: new Error('account-A failure'),
  locationsData: [{ id: 'location-A' }], locationsRefreshError: new Error('account-A locations'), isLocationsRefreshing: true,
  devicesData: [{ id: 'device-A' }], deviceUsageSnapshot: { usage: [{ deviceId: 'device-A' }] },
};

for (const name of names) {
  test(`${name} from A is hidden on B's first render before effect cleanup`, () => {
    const h = harness();
    try {
      const a = h.render(); a[`set${name[0].toUpperCase()}${name.slice(1)}`](fixtures[name]);
      assert.equal(h.render()[name], fixtures[name]); h.change('B');
      assert.equal(h.render('B')[name], name === 'isLocationsRefreshing' ? false : null);
    } finally { h.close(); }
  });
  test(`retained ${name} setter cannot publish after A-B-A login replacement`, () => {
    const h = harness();
    try {
      const a = h.render(), setter = `set${name[0].toUpperCase()}${name.slice(1)}`;
      h.change('B'); h.render('B'); h.change('A'); const next = h.render('A'); next[setter](name === 'isLocationsRefreshing' ? false : { marker: 'current-A' });
      const current = h.render('A')[name]; a[setter](fixtures[name]); assert.equal(h.render('A')[name], current);
    } finally { h.close(); }
  });
}

test('B does not hydrate/persist A snapshots or skip its own entitlement request', async () => {
  const bResponse = gate();
  const h = harness({ api: token => token === 'token-B' ? bResponse.promise : Promise.resolve(fixtures.entitlementData) });
  try {
    h.render(); h.commit(); await tick();
    let a = h.render(); a.setPersistedEntitlement(fixtures.persistedEntitlement); a.setLocationsData(fixtures.locationsData); a.setDevicesData(fixtures.devicesData);
    h.render(); h.commit(); await tick(); h.render(); h.commit(); await tick();
    h.change('B'); const b = h.render('B'); h.commit(); await tick();
    assert.equal(h.requests.filter(token => token === 'token-B').length, 1, 'B must fetch its own entitlement rather than accepting freshly seeded A');
    assert.equal(b.entitlementData, null);
    assert.equal(h.query.getQueryData(['entitlement', 'token-B']), undefined);
    assert.ok(!h.writes.some(item => item.user === 'B' && (item.value?.displayName === 'account-A' || item.value?.[0]?.id?.endsWith('-A'))));
    bResponse.resolve({ active: false, vpnAccess: false, displayName: 'account-B' }); await tick();
    assert.equal(h.render('B').entitlementData.displayName, 'account-B');
  } finally { bResponse.resolve({ active: false, vpnAccess: false }); await tick(); h.close(); }
});

test('late cached reads for A cannot populate B before the old effect cleanup', async () => {
  const old = gate(), h = harness({ cached: { entitlement: () => old.promise } });
  try {
    h.render(); h.commit(); h.change('B'); h.render('B'); old.resolve(fixtures.persistedEntitlement); await tick();
    assert.equal(h.render('B').persistedEntitlement, null);
  } finally { old.resolve(null); await tick(); h.close(); }
});

test('same-login token rotation retains account snapshots and preserves cache reuse', async () => {
  const h = harness();
  try {
    const first = h.render(); first.setPersistedEntitlement(fixtures.persistedEntitlement); first.setEntitlementData(fixtures.entitlementData);
    const next = h.render('A', 'token-A-refreshed'); h.commit(); await tick();
    assert.equal(next.entitlementData, fixtures.entitlementData); assert.equal(next.persistedEntitlement, fixtures.persistedEntitlement);
    assert.equal(h.query.getQueryData(['entitlement', 'token-A-refreshed']).displayName, 'account-A');
  } finally { h.close(); }
});

test('a functional update in B never receives A devices as its previous value', () => {
  const h = harness();
  try {
    h.render().setDevicesData(fixtures.devicesData); h.change('B');
    h.render('B').setDevicesData(previous => [...(previous || []), { id: 'device-B' }]);
    assert.deepEqual(h.render('B').devicesData, [{ id: 'device-B' }]);
  } finally { h.close(); }
});

test('a state updater queued in A is checked again when React applies it after B renders', () => {
  const h = harness();
  try {
    const a = h.render(); h.deferState(); a.setEntitlementData(fixtures.entitlementData);
    h.change('B'); h.render('B'); h.flushState();
    assert.equal(h.render('B').entitlementData, null);
  } finally { h.flushState(); h.close(); }
});

test('B entitlement failure cannot fall back to A entitlement or persist it as B', async () => {
  const h = harness({ api: token => token === 'token-B' ? Promise.reject(new Error('account-B failed')) : Promise.resolve(fixtures.entitlementData) });
  try {
    h.render(); h.commit(); await tick(); const a = h.render(); a.setPersistedEntitlement(fixtures.persistedEntitlement);
    h.render(); h.commit(); await tick();
    h.change('B'); h.render('B'); h.commit(); await tick(); const b = h.render('B');
    assert.equal(b.entitlementData, null); assert.equal(b.persistedEntitlement, null);
    assert.equal(b.entitlementError.message, 'account-B failed');
    assert.ok(!h.writes.some(item => item.user === 'B' && item.value?.displayName === 'account-A'));
  } finally { h.close(); }
});

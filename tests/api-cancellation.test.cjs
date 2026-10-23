const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const test = require('node:test');
const { spawnSync } = require('node:child_process');
const { QueryClient, isCancelledError } = require('@tanstack/react-query');

const root = path.resolve(process.env.VEX_CANCELLATION_SOURCE_ROOT || path.join(__dirname, '..'));
const gate = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
const tick = () => new Promise(resolve => setImmediate(resolve));
const flush = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };
const paid = { active: true, vpnAccess: true };
const pair = { publicKey: 'public', privateKey: 'private', keyEpoch: 1 };
const device = { id: 'device', user_id: 'owner', status: 'active', public_key: pair.publicKey, psk_epoch: 1,
  assigned_ipv4: '10.0.0.2', external_device_id: 'installation', protocol: 'amneziawg',
  provisioning_mode: 'managed_native', client_key_ownership: 'client' };
const profile = { config: 'Address = 10.0.0.2/32', version: 1, device_id: 'device', client_public_key: pair.publicKey, client_key_epoch: 1 };
const response = value => ({ ok: true, status: 200, text: async () => JSON.stringify(value) });
const tracked = promise => {
  const result = { done: false };
  result.promise = promise.then(value => Object.assign(result, { done: true, value }), error => Object.assign(result, { done: true, error }));
  return result;
};
const cancelled = result => { assert.equal(result.done, true); assert.equal(result.error?.code, 'request_cancelled'); };

// Real API, queue and Query code; adapters replace only platform/storage/UI
// boundaries. Each loader has its own module state and controlled transport.
function harness({ fetch = async () => response({}), appInfo = async () => ({ platform: 'web' }), platform = 'web', adapters = {} } = {}) {
  const modules = new Map(), timers = new Set();
  const native = { supportsNativeRoutingPolicy: () => false, getOrCreateWireGuardKeyPair: async () => pair };
  const overrides = {
    'react-native': { Platform: { OS: platform, Version: 36 } },
    'expo-secure-store': { getItemAsync: async () => null, setItemAsync: async () => {} },
    '@/native/appInfo': { getAppInfo: appInfo, getOrCreateDeviceId: async () => 'installation', VEX_API_CLIENT_VERSION: '1', VEX_CONFIG_SCHEMA_VERSION: 1 },
    '@/native/vexVpn': native,
    '@/native/deviceIdentity': { getOrCreateDeviceIdentity: async () => undefined },
    '@/native/vpnAccountIdentity': {},
    '@/vpn/hotProfileCache': { loadHotVpnProfile: async () => null },
    ...adapters,
  };
  const key = file => file.startsWith('@/') ? path.join(root, 'src', file.slice(2)) : file;
  const mapped = new Map(Object.entries(overrides).map(([name, value]) => [key(name), value]));
  function load(file) {
    file = key(file);
    if (mapped.has(file)) return mapped.get(file);
    if (modules.has(file)) return modules.get(file).exports;
    const module = { exports: {} }; modules.set(file, module);
    const code = ts.transpileModule(fs.readFileSync(file + '.ts', 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText;
    const requireFixture = name => {
      if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name));
      if (name.startsWith('@/')) return load(name);
      if (mapped.has(name)) return mapped.get(name);
      throw new Error(`Unadapted platform dependency ${name}`);
    };
    const setTimer = (callback, ms) => {
      const timer = setTimeout(() => { timers.delete(timer); callback(); }, ms);
      timers.add(timer); return timer;
    };
    const clearTimer = timer => { timers.delete(timer); clearTimeout(timer); };
    new Function('require', 'module', 'exports', 'process', 'fetch', '__DEV__', 'setTimeout', 'clearTimeout', code)(
      requireFixture, module, module.exports, { env: { EXPO_PUBLIC_VEX_API_BASE_URL: 'https://fixture.example.test' } }, fetch, false, setTimer, clearTimer);
    return module.exports;
  }
  return { load, timers };
}

test('session replacement during native setup leaves no unhandled account preparation', () => {
  // A separate strict process catches an orphan rejection without installing a
  // global handler that could hide failures from the other cancellation tests.
  const helpers = fs.readFileSync(__filename, 'utf8').split("test('session replacement during native setup")[0];
  const script = helpers + `
    (async () => {
      const controller = new AbortController(); let current = true, identityCalls = 0, httpCalls = 0;
      const h = harness({ platform: 'android', adapters: {
        '@/native/vpnAccountIdentity': { getOrCreateVpnAccountIdentity: async () => {
          identityCalls++; current = false; controller.abort();
          throw new (h.load('@/vpn/sessionOperation').SessionOperationSupersededError)();
        } },
      }, fetch: async () => { httpCalls++; throw Error('Unexpected stale HTTP request'); } });
      const result = tracked(h.load('@/vpn/profile').resolveVpnProfile('token', paid, 'de', {
        forceRefresh: true, userId: 'owner', signal: controller.signal, isCurrentSessionOperation: () => current,
      }));
      await result.promise;
      await h.load('@/vpn/profileRequestQueue').runProfileRequest(async () => 'barrier');
      await tick();
      cancelled(result); assert.equal(identityCalls, 1); assert.equal(httpCalls, 0); assert.equal(h.timers.size, 0);
      console.log('PASS native preparation rejection remains observed');
    })().catch(error => { console.error(error); process.exitCode = 1; });
  `;
  const child = spawnSync(process.execPath, ['--unhandled-rejections=strict', '-e', script], {
    cwd: root, env: { ...process.env, VEX_CANCELLATION_SOURCE_ROOT: root }, encoding: 'utf8', timeout: 15000,
  });
  assert.equal(child.status, 0, child.error?.message || child.stdout + child.stderr);
  assert.match(child.stdout, /PASS native preparation rejection remains observed/);
});

for (const body of ['QSECRET', '', '{', '[1,', '{"field":"fixture"']) {
  test(`malformed successful JSON is a private protocol error: ${JSON.stringify(body)}`, async () => {
    const h = harness({ fetch: async () => ({ ok: true, status: 200, text: async () => body }) });
    let failure;
    try { await h.load('@/api/client').jsonRequest('/v1/fixture'); }
    catch (error) { failure = error; }
    assert.ok(failure, 'invalid JSON was admitted');
    assert.ok(!failure.message.includes('QSECRET'), 'parser diagnostics exposed response content');
    assert.ok(!failure.stack.includes('QSECRET'), 'parser stack exposed response content');
    assert.equal(failure.code, 'api_response_invalid');
    assert.equal(failure.status, undefined, 'a local decode failure must not invent an HTTP outage');
    assert.equal(h.load('@/api/error').isTechnicalWorksError(failure), false);
    assert.equal(h.timers.size, 0);
  });
}
for (const method of ['GET', 'POST']) {
  test(`Query does not replay ${method} after a malformed successful JSON response`, async () => {
    let requests = 0;
    const h = harness({ fetch: async () => { requests++; return { ok: true, status: 200, text: async () => '{' }; } });
    const query = new QueryClient({ defaultOptions: { queries: {
      retry: h.load('@/api/queryRetry').createApiQueryRetry(2), retryDelay: 0, gcTime: Infinity,
    } } });
    try {
      let failure;
      try {
        await query.fetchQuery({ queryKey: ['malformed-fixture'], queryFn: () =>
          h.load('@/api/client').jsonRequest('/v1/fixture', { method, ...(method === 'POST' ? { idempotencyKey: 'inert-fixture' } : {}) }) });
      } catch (error) { failure = error; }
      assert.equal(requests, 1, 'protocol failure replayed the complete API operation');
      assert.equal(failure?.code, 'api_response_invalid');
      assert.equal(h.timers.size, 0);
    } finally { query.clear(); }
  });
}
for (const body of ['{"ok":true}', 'QSECRET']) {
  test(`caller cancellation after HTTP cleanup precedes JSON decode: ${body}`, async () => {
    const controller = new AbortController();
    const remove = controller.signal.removeEventListener.bind(controller.signal);
    controller.signal.removeEventListener = (...args) => {
      remove(...args);
      // HTTP has settled, but jsonRequest's await continuation has not run.
      queueMicrotask(() => controller.abort('inert-private-cancellation-reason'));
    };
    const h = harness({ fetch: async () => ({ ok: true, status: 200, text: async () => body }) });
    await assert.rejects(h.load('@/api/client').jsonRequest('/v1/fixture', { signal: controller.signal }),
      error => error.code === 'request_cancelled' && !error.message.includes('inert-private'));
    assert.equal(h.timers.size, 0);
  });
}
test('a transport-origin SyntaxError is not relabeled as a JSON body failure', async () => {
  const failure = new SyntaxError('inert transport preparation failure');
  const h = harness({ fetch: async () => { throw failure; } });
  await assert.rejects(h.load('@/api/client').jsonRequest('/v1/fixture'), error => error === failure);
});
for (const value of [null, { ok: true }, [1, 'ok'], false, 42, 'value']) {
  test(`generic JSON retains valid scalar/object/array semantics: ${JSON.stringify(value)}`, async () => {
    const h = harness({ fetch: async () => response(value) });
    assert.deepEqual(await h.load('@/api/client').jsonRequest('/v1/fixture'), value);
    assert.equal(h.timers.size, 0);
  });
}
for (const body of ['', '[Interface]\nPrivateKey = inert-fixture\n']) {
  test(`raw responses retain non-JSON and empty content: ${JSON.stringify(body)}`, async () => {
    const h = harness({ fetch: async () => ({ ok: true, status: 200, text: async () => body }) });
    assert.equal(await h.load('@/api/client').rawRequest('/v1/fixture'), body);
    assert.equal(h.timers.size, 0);
  });
}

test('an already cancelled request does no metadata lookup or HTTP work', async () => {
  let setup = 0, calls = 0;
  const h = harness({ appInfo: async () => { setup++; return {}; }, fetch: async () => { calls++; return response({}); } });
  const controller = new AbortController(); controller.abort('inert-private-reason');
  const result = tracked(h.load('@/api/client').jsonRequest('/v1/devices', { signal: controller.signal }));
  await result.promise; cancelled(result);
  assert.equal(setup, 0); assert.equal(calls, 0); assert.equal(h.timers.size, 0);
  assert.ok(!result.error.message.includes('inert-private-reason'));
});

for (const stage of ['metadata', 'headers', 'body']) {
  test(`caller cancellation settles stalled ${stage} and blocks late work`, async () => {
    const hold = gate(), controller = new AbortController(); let calls = 0, transportSignal;
    const h = harness({
      appInfo: stage === 'metadata' ? () => hold.promise : async () => ({}),
      fetch: async (_, { signal }) => {
        calls++; transportSignal = signal;
        if (stage === 'headers') return hold.promise;
        return { ok: true, status: 200, text: () => hold.promise };
      },
    });
    const result = tracked(h.load('@/api/client').jsonRequest('/v1/devices', { signal: controller.signal }));
    await tick(); controller.abort(); await tick();
    const immediate = result.done, error = result.error;
    hold.resolve(stage === 'metadata' ? {} : stage === 'headers' ? response({}) : '{}');
    await result.promise; await tick();
    assert.equal(immediate, true); assert.equal(error?.code, 'request_cancelled');
    if (stage === 'metadata') assert.equal(calls, 0);
    else { assert.equal(calls, 1); assert.equal(transportSignal.aborted, true); assert.notEqual(transportSignal, controller.signal); }
    assert.equal(h.timers.size, 0);
    assert.equal(h.load('@/api/error').isTechnicalWorksError(error), false);
  });
}

for (const first of ['cancel', 'timeout']) {
  test(`the first terminal cause wins: ${first}`, async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
    const hold = gate(), controller = new AbortController();
    const h = harness({ fetch: () => hold.promise });
    const result = tracked(h.load('@/api/client').rawRequest('/v1/devices', { timeout: 1000, signal: controller.signal }));
    await flush();
    if (first === 'cancel') { controller.abort(); t.mock.timers.tick(1000); }
    else { t.mock.timers.tick(1000); controller.abort(); }
    await flush(); const immediate = result.done, code = result.error?.code;
    hold.resolve(response({})); await result.promise;
    assert.equal(immediate, true); assert.equal(code, first === 'cancel' ? 'request_cancelled' : 'request_timeout');
    assert.equal(h.timers.size, 0);
  });
}

test('cancellation clears Retry-After/backoff without a later GET retry', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  let calls = 0; const controller = new AbortController();
  const h = harness({ fetch: async () => { calls++; return { ok: false, status: 503, headers: { get: () => '2' }, text: async () => '{}' }; } });
  const result = tracked(h.load('@/api/client').rawRequest('/v1/devices', { timeout: 5000, signal: controller.signal }));
  await flush(); controller.abort(); await flush();
  const immediate = result.done, code = result.error?.code, activeTimers = h.timers.size;
  t.mock.timers.tick(5000); await flush(); await result.promise;
  assert.equal(immediate, true); assert.equal(code, 'request_cancelled'); assert.equal(activeTimers, 0); assert.equal(calls, 1);
});

for (const outcome of ['success', 'failure', 'cancel']) {
  test(`borrowed abort listener is detached after ${outcome}`, async () => {
    const controller = new AbortController(), listeners = new Set(), hold = gate(); let signal;
    const add = controller.signal.addEventListener.bind(controller.signal), remove = controller.signal.removeEventListener.bind(controller.signal);
    controller.signal.addEventListener = (name, listener, options) => { if (name === 'abort') listeners.add(listener); add(name, listener, options); };
    controller.signal.removeEventListener = (name, listener) => { if (name === 'abort') listeners.delete(listener); remove(name, listener); };
    const h = harness({ fetch: async (_, init) => { signal = init.signal; return hold.promise; } });
    const result = tracked(h.load('@/api/client').rawRequest('/v1/devices', { signal: controller.signal, retryCount: 0 }));
    await tick();
    if (outcome === 'cancel') controller.abort();
    if (outcome === 'failure') hold.reject(new Error('local fixture failure')); else hold.resolve(response({}));
    await result.promise; await tick();
    assert.equal(listeners.size, 0); assert.equal(h.timers.size, 0); assert.equal(signal.aborted, true);
    assert.equal(controller.signal.aborted, outcome === 'cancel');
  });
}

test('a cancelled POST is never replayed, including with an idempotency key', async () => {
  const hold = gate(), controller = new AbortController(); let calls = 0;
  const h = harness({ fetch: () => { calls++; return hold.promise; } });
  const result = tracked(h.load('@/api/client').rawRequest('/v1/devices', { signal: controller.signal, method: 'POST', body: {}, idempotencyKey: 'fixture' }));
  await tick(); controller.abort(); await tick(); const immediate = result.done;
  hold.resolve(response({})); await result.promise; cancelled(result); assert.equal(immediate, true); assert.equal(calls, 1);
});

for (const endpoint of ['entitlement', 'devices', 'locations', 'usage', 'policy', 'me', 'update']) {
  test(`real ${endpoint} endpoint forwards cancellation without putting signal on the wire`, async () => {
    const hold = gate(), controller = new AbortController(); let init;
    const h = harness({ fetch: (_, options) => { init = options; return hold.promise; } });
    const calls = {
      entitlement: () => h.load('@/api/billing').entitlement('token', controller.signal),
      devices: () => h.load('@/api/vpn').vpnDevices('token', controller.signal),
      locations: () => h.load('@/api/vpn').vpnLocations('token', controller.signal),
      usage: () => h.load('@/api/vpn').vpnDeviceUsageSnapshot('token', 'device', controller.signal),
      policy: () => h.load('@/api/vpn').vpnResiliencePolicy('token', controller.signal),
      me: () => h.load('@/api/auth').me('token', controller.signal),
      update: () => h.load('@/api/updates').appUpdateCheck({ platform: 'android', appVersion: '1.0.73', buildNumber: 1, signal: controller.signal }),
    };
    const result = tracked(calls[endpoint]()); await tick(); controller.abort(); await tick();
    const aborted = init.signal.aborted;
    hold.resolve(response(endpoint === 'devices' || endpoint === 'locations' ? [] : {})); await result.promise;
    cancelled(result); assert.equal(aborted, true);
    assert.ok(!Object.hasOwn(JSON.parse(init.body || '{}'), 'signal')); assert.ok(!Object.hasOwn(init.headers, 'signal'));
  });
}

const invalidUpdateControls = [
  ['empty object', {}], ['missing availability', { required: false }], ['missing requirement', { updateAvailable: false }],
  ...[null, [], [false], true, 'false', 0].map(value => [`root ${JSON.stringify(value)}`, value]),
  ...['updateAvailable', 'required'].flatMap(field => [null, 0, 1, 'false', 'true', [], {}]
    .map(value => [`${field} ${JSON.stringify(value)}`, { updateAvailable: false, required: false, [field]: value }])),
  ...[0, 1, 'false', 'true', [], {}].map(value => [`blocked ${JSON.stringify(value)}`,
    { updateAvailable: false, required: false, currentBuildBlocked: value }]),
];
for (const [name, payload] of invalidUpdateControls) {
  test(`real update response rejects ${name} instead of caching a successful update decision`, async () => {
    let requests = 0;
    const h = harness({ fetch: async () => { requests++; return response(payload); } });
    const query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
    try {
      await assert.rejects(query.fetchQuery({ queryKey: ['update-fixture'], queryFn: () =>
        h.load('@/api/updates').appUpdateCheck({ platform: 'android', appVersion: '1.0.73', buildNumber: 1 }) }),
      error => error.code === 'api_response_invalid' && error.status === 502);
      assert.equal(query.getQueryState(['update-fixture']).status, 'error');
      assert.equal(query.getQueryData(['update-fixture']), undefined);
      assert.equal(requests, 1, 'invalid replies must not replay the POST');
      assert.equal(h.timers.size, 0);
    } finally { query.clear(); }
  });
}
test('an invalid update refresh cannot overwrite the last valid cached decision', async () => {
  const h = harness({ fetch: async () => response({}) });
  const query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const last = { updateAvailable: true, required: true, currentBuildBlocked: true, latestVersion: '1.3.0' };
  try {
    query.setQueryData(['update-fixture'], last);
    await assert.rejects(query.fetchQuery({ queryKey: ['update-fixture'], queryFn: () =>
      h.load('@/api/updates').appUpdateCheck({ platform: 'android', appVersion: '1.0.73', buildNumber: 1 }) }),
    error => error.code === 'api_response_invalid');
    assert.equal(query.getQueryState(['update-fixture']).status, 'error');
    assert.deepEqual(query.getQueryData(['update-fixture']), last);
    assert.equal(h.timers.size, 0);
  } finally { query.clear(); }
});
for (const flags of [
  { updateAvailable: false, required: false },
  { updateAvailable: false, required: true, currentBuildBlocked: true },
  { updateAvailable: true, required: false, currentBuildBlocked: false },
  { updateAvailable: true, required: true, currentBuildBlocked: true },
  { updateAvailable: false, required: false, currentBuildBlocked: null },
]) {
  test(`valid update flags retain omission and independent control values ${JSON.stringify(flags)}`, async () => {
    const h = harness({ fetch: async () => response(flags) });
    const update = await h.load('@/api/updates').appUpdateCheck({ platform: 'android', appVersion: '1.0.73', buildNumber: 1 });
    assert.equal(update.updateAvailable, flags.updateAvailable);
    assert.equal(update.required, flags.required);
    assert.equal(update.currentBuildBlocked, flags.currentBuildBlocked ?? false);
    assert.equal(update.latestVersion, ''); assert.equal(update.latestBuild, 0);
    assert.equal(update.downloadUrl, ''); assert.equal(h.timers.size, 0);
  });
}

for (const action of ['cancelQueries', 'removeQueries']) {
  test(`real QueryClient.${action} aborts endpoint transport and allows the replacement query`, async () => {
    const hold = gate(), seen = [];
    const h = harness({ fetch: (_, init) => { seen.push(init.signal); return seen.length === 1 ? hold.promise : Promise.resolve(response(paid)); } });
    const api = h.load('@/api/billing'), query = new QueryClient({ defaultOptions: { queries: { retry: h.load('@/api/queryRetry').createApiQueryRetry(2), gcTime: 0 } } });
    try {
      const old = tracked(query.fetchQuery({ queryKey: ['entitlement', 'A'], queryFn: ({ signal }) => api.entitlement('A', signal) }));
      await tick(); await query[action]({ queryKey: ['entitlement', 'A'] });
      assert.ok(isCancelledError((await old.promise).error)); const aborted = seen[0].aborted;
      hold.resolve(response({ active: false })); await tick();
      const current = await query.fetchQuery({ queryKey: ['entitlement', 'B'], queryFn: ({ signal }) => api.entitlement('B', signal) });
      assert.equal(current.active, true); assert.equal(aborted, true); assert.equal(seen.length, 2); assert.equal(h.timers.size, 0);
    } finally { hold.resolve(response({})); query.clear(); }
  });
}

test('Query retry policy never repeats neutral caller cancellation', async () => {
  const h = harness(), query = new QueryClient({ defaultOptions: { queries: { retry: h.load('@/api/queryRetry').createApiQueryRetry(2), retryDelay: 0, gcTime: 0 } } });
  let calls = 0;
  try {
    await assert.rejects(query.fetchQuery({ queryKey: ['fixture'], queryFn: async () => {
      calls++; throw new (h.load('@/api/error').ApiRequestError)('Запрос отменён.', { code: 'request_cancelled' });
    } }), error => error.code === 'request_cancelled');
    assert.equal(calls, 1);
  } finally { query.clear(); }
});

test('cancelled queued profile never starts, and the next request keeps its slot', async () => {
  const h = harness(), { runProfileRequest } = h.load('@/vpn/profileRequestQueue'), hold = gate(), controller = new AbortController(); let staleCalls = 0;
  const first = runProfileRequest(() => hold.promise);
  const old = tracked(runProfileRequest(async () => { staleCalls++; }, undefined, 'background', '', controller.signal));
  await tick(); controller.abort(); await tick(); const immediate = old.done;
  const current = runProfileRequest(async () => 'current'); hold.resolve('first'); await first; await old.promise;
  assert.equal(await current, 'current'); cancelled(old); assert.equal(immediate, true); assert.equal(staleCalls, 0);
});

for (const cancelledBorrower of ['leader', 'follower', 'both']) {
  test(`profile coalescing isolates ${cancelledBorrower} cancellation`, async () => {
    const h = harness(), { runProfileRequest } = h.load('@/vpn/profileRequestQueue'), hold = gate();
    const leader = new AbortController(), follower = new AbortController(); let ownerSignal, followerCalls = 0;
    const a = tracked(runProfileRequest(async signal => { ownerSignal = signal; await hold.promise; return 'owned'; }, undefined, 'background', 'same', leader.signal));
    await tick();
    const b = tracked(runProfileRequest(async () => { followerCalls++; return 'duplicate'; }, undefined, 'foreground', 'same', follower.signal));
    if (cancelledBorrower !== 'follower') leader.abort();
    if (cancelledBorrower !== 'leader') follower.abort();
    await tick(); const immediateA = a.done, immediateB = b.done, aborted = ownerSignal?.aborted;
    hold.resolve(); await a.promise; await b.promise;
    assert.equal(immediateA, cancelledBorrower !== 'follower'); assert.equal(immediateB, cancelledBorrower !== 'leader');
    assert.equal(aborted, cancelledBorrower === 'both'); assert.equal(followerCalls, 0);
    if (cancelledBorrower !== 'follower') cancelled(a); else assert.equal(a.value, 'owned');
    if (cancelledBorrower !== 'leader') cancelled(b); else assert.equal(b.value, 'owned');
  });
}

test('a cancelled joined foreground waiter is not retried after background failure', async () => {
  const h = harness(), { runProfileRequest } = h.load('@/vpn/profileRequestQueue'), hold = gate(), controller = new AbortController(); let calls = 0;
  const a = tracked(runProfileRequest(() => hold.promise, undefined, 'background', 'same'));
  await tick(); const b = tracked(runProfileRequest(async () => { calls++; return 'duplicate'; }, undefined, 'foreground', 'same', controller.signal));
  controller.abort(); hold.reject(new Error('background failed')); await a.promise; await b.promise;
  await runProfileRequest(async () => 'barrier'); cancelled(b); assert.equal(calls, 0);
});

for (const stage of ['metadata', 'devices', 'profile']) {
  test(`profile resolution cancellation during ${stage} starts no fallback or later HTTP stage`, async () => {
    const hold = gate(), controller = new AbortController(), calls = [];
    const h = harness({ appInfo: stage === 'metadata' ? () => hold.promise : async () => ({ platform: 'web' }), fetch: async (url, init) => {
      const requestPath = new URL(url).pathname; calls.push(requestPath);
      if (requestPath === '/v1/devices') return stage === 'devices' ? hold.promise : response([device]);
      if (requestPath === '/v1/vpn/profile') return hold.promise;
      throw new Error(`Unexpected fallback ${requestPath} ${init.method}`);
    } });
    const result = tracked(h.load('@/vpn/profile').resolveVpnProfile('token', paid, 'de', { forceRefresh: true, signal: controller.signal }));
    await tick(); controller.abort(); await tick(); const before = calls.slice(), immediate = result.done;
    hold.resolve(stage === 'metadata' ? { platform: 'web' } : response(stage === 'devices' ? [device] : profile));
    await result.promise; await h.load('@/vpn/profileRequestQueue').runProfileRequest(async () => 'barrier'); cancelled(result); assert.equal(immediate, true); assert.deepEqual(calls, before);
    assert.ok(!calls.some(name => name.includes('config'))); assert.equal(h.timers.size, 0);
  });
}

test('profile borrower cancellation retains queue ownership until a dispatched key write settles', async () => {
  const hold = gate(), controller = new AbortController(), calls = []; let writeSignal;
  const h = harness({ fetch: async (url, init) => {
    const requestPath = new URL(url).pathname; calls.push(requestPath);
    if (requestPath === '/v1/devices') return response([{ ...device, public_key: 'old-public' }]);
    if (requestPath === '/v1/vpn/rotate-key') { writeSignal = init.signal; return hold.promise; }
    if (requestPath === '/v1/vpn/profile') return response(profile);
    throw Error(`Unexpected stage ${requestPath}`);
  } });
  const resolver = h.load('@/vpn/profile'), queue = h.load('@/vpn/profileRequestQueue');
  const old = tracked(resolver.resolveVpnProfile('token', paid, 'de', { forceRefresh: true, signal: controller.signal }));
  await tick(); assert.ok(writeSignal); controller.abort(); await tick(); const immediate = old.done;
  let nextStarted = false; const next = queue.runProfileRequest(async () => { nextStarted = true; return 'next'; });
  await tick(); const overlapped = nextStarted, writeAborted = writeSignal.aborted;
  hold.resolve(response({ device })); await old.promise; await next;
  cancelled(old); assert.equal(immediate, true); assert.equal(overlapped, false); assert.equal(writeAborted, false);
  assert.equal(calls.filter(name => name === '/v1/vpn/rotate-key').length, 1); assert.ok(!calls.includes('/v1/vpn/profile'));
});

test('cancelled profile issuance retains its queue slot until the dispatched profile GET completes', async () => {
  const hold = gate(), controller = new AbortController(), calls = []; let issuanceSignal;
  const h = harness({ fetch: async (url, init) => {
    const route = new URL(url).pathname; calls.push(route);
    if (route === '/v1/devices') return response([device]);
    if (route === '/v1/vpn/profile') { issuanceSignal = init.signal; return hold.promise; }
    throw Error(`Unexpected issuance stage ${route}`);
  } });
  const resolver = h.load('@/vpn/profile'), queue = h.load('@/vpn/profileRequestQueue');
  const old = tracked(resolver.resolveVpnProfile('token', paid, 'de', { forceRefresh: true, signal: controller.signal }));
  await tick(); assert.ok(issuanceSignal); controller.abort(); await tick();
  const immediate = old.done, aborted = issuanceSignal.aborted;
  let nextStarted = false; const next = queue.runProfileRequest(async () => { nextStarted = true; return 'current'; });
  await tick(); const overlapped = nextStarted;
  hold.resolve(response(profile)); await old.promise; assert.equal(await next, 'current');
  cancelled(old); assert.equal(immediate, true); assert.equal(aborted, false); assert.equal(overlapped, false);
  assert.equal(calls.filter(route => route === '/v1/vpn/profile').length, 1); assert.equal(h.timers.size, 0);
});

test('two profile callers share registration and retain its durable confirmation after one cancels', async () => {
  const posted = gate(), persisted = gate(), controller = new AbortController();
  let registrationSignal, confirmations = 0, registrations = 0, profileRequests = 0;
  const identity = { installationId: 'installation', externalDeviceId: 'installation', keyScope: 'scope', keyPair: pair, ownedDevices: [], legacyRegistrationPending: true };
  const h = harness({ platform: 'android', adapters: {
    '@/native/deviceIdentity': { getOrCreateDeviceIdentity: async () => ({ publicKey: 'identity', sign: async () => 'signature' }), deviceIdentitySignaturePayload: () => 'payload' },
    '@/native/vpnAccountIdentity': {
      getOrCreateVpnAccountIdentity: async () => identity, withVpnAccountIdentity: async (_, operation) => operation(identity),
      pendingVpnAccountKeyPair: async () => undefined, vpnAccountRegistrationIdempotencyKey: () => 'fixture-registration',
      confirmVpnAccountRegistration: async () => { confirmations++; await persisted.promise; },
    },
  }, fetch: async (url, init) => {
    const route = new URL(url).pathname;
    if (route === '/v1/devices/identity-challenge') return response({ id: 'challenge', nonce: 'nonce' });
    if (route === '/v1/devices/register') { registrations++; registrationSignal = init.signal; return posted.promise; }
    if (route === '/v1/vpn/profile') { profileRequests++; return response(profile); }
    throw Error(`Unexpected registration stage ${route}`);
  } });
  const api = h.load('@/api/vpn'), client = { platform: 'android', deviceName: 'fixture' };
  const a = tracked(api.preparedTunnel('token', client, { locationId: 'de', userId: 'owner', signal: controller.signal }));
  await tick(); assert.ok(registrationSignal);
  const b = tracked(api.preparedTunnel('token', client, { locationId: 'de', userId: 'owner' }));
  await tick(); controller.abort(); const stoppedWrite = registrationSignal.aborted;
  posted.resolve(response({ device })); await tick();
  const prematurelyResolved = b.done, earlyProfileRequests = profileRequests;
  persisted.resolve(); await a.promise; await b.promise;
  cancelled(a); assert.equal(b.value.device.id, device.id); assert.equal(stoppedWrite, false);
  assert.equal(prematurelyResolved, false); assert.equal(earlyProfileRequests, 0);
  assert.equal(registrations, 1); assert.equal(confirmations, 1); assert.equal(profileRequests, 1);
});

for (const callback of ['fetchEntitlement', 'fetchVpnLocations', 'fetchVpnDevices']) {
  test(`actual ${callback} Query callback consumes its QueryClient signal`, async () => {
    const hold = gate(); let transportSignal;
    const h = harness({ fetch: (_, init) => { transportSignal = init.signal; return hold.promise; } });
    const source = ts.createSourceFile('connection.ts', fs.readFileSync(path.join(root, 'src/vpn/useVpnConnection.ts'), 'utf8'), ts.ScriptTarget.Latest, true);
    let declaration;
    const visit = node => { if (ts.isVariableDeclaration(node) && node.name.getText(source) === callback) declaration = node; ts.forEachChild(node, visit); };
    visit(source); assert.ok(declaration);
    const code = ts.transpileModule(`const ${declaration.getText(source)};`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
    const queryFn = new Function('useCallback', 'accessToken', 'entitlement', 'vpnLocations', 'vpnDevices', `${code}; return ${callback};`)(
      fn => fn, 'token', h.load('@/api/billing').entitlement, h.load('@/api/vpn').vpnLocations, h.load('@/api/vpn').vpnDevices);
    const query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
    try {
      const result = tracked(query.fetchQuery({ queryKey: ['fixture'], queryFn })); await tick();
      query.removeQueries({ queryKey: ['fixture'] }); await result.promise; const aborted = transportSignal.aborted;
      hold.resolve(response(callback === 'fetchEntitlement' ? paid : [])); await tick(); assert.equal(aborted, true);
    } finally { hold.resolve(response([])); query.clear(); }
  });
}

test('the actual background profile hook consumes Query cancellation without reporting a failure', async () => {
  const hold = gate(), effects = [], cleanups = []; let transportSignal, reported = 0;
  const query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  const h = harness({ fetch: (_, init) => { transportSignal = init.signal; return hold.promise; }, adapters: {
    react: { useCallback: fn => fn, useMemo: fn => fn(), useRef: current => ({ current }), useState: value => [value, () => {}], useEffect: fn => effects.push(fn) },
    '@tanstack/react-query': { useQueryClient: () => query, isCancelledError },
    '@/vpn/hotProfileCache': { hydrateHotVpnProfilesToQueryCache: async () => [], clearHotVpnProfiles: async () => {}, saveHotVpnProfile: async () => {} },
  } });
  try {
    h.load('@/vpn/useVpnProfileState').useVpnProfileState({ accessToken: 'token', isCurrentSessionOperation: () => true,
      hasVpnAccess: true, knownEntitlement: paid, selectedLocationId: 'de', routingMode: 'full_tunnel', realtimeConnected: true,
      profileRefreshMs: 60000, onProfileRefreshFailed: () => { reported++; } });
    effects.forEach(fn => cleanups.push(fn())); await tick(); assert.ok(transportSignal);
    query.removeQueries({ queryKey: ['vpn-profile'] }); await tick(); const aborted = transportSignal.aborted;
    hold.resolve(response([device])); await tick(); assert.equal(aborted, true); assert.equal(reported, 0);
  } finally { cleanups.forEach(fn => fn?.()); hold.resolve(response([device])); query.clear(); }
});

for (const stage of ['metadata', 'http']) {
  test(`the actual update hook consumes cancellation during ${stage}`, async () => {
    const hold = gate(), controller = new AbortController(); let transportSignal, calls = 0;
    const h = harness({ appInfo: stage === 'metadata' ? () => hold.promise : async () => ({ platform: 'android', version: '1.0.73', channel: 'stable' }),
      fetch: (_, init) => { calls++; transportSignal = init.signal; return hold.promise; }, adapters: {
        react: { useCallback: fn => fn, useMemo: fn => fn() }, '@tanstack/react-query': { useQuery: options => options },
        '@/auth/session-context': { useSession: () => ({ sessionRevision: 1, isCurrentSessionOperation: () => true }) },
      } });
    const options = h.load('@/components/mobile-app-update-query').useMobileAppUpdateQuery('android', 1);
    const result = tracked(options.queryFn({ signal: controller.signal })); await tick(); controller.abort(); await tick();
    const immediate = result.done, before = calls;
    hold.resolve(stage === 'metadata' ? { version: '1.0.73' } : response({})); await result.promise; await tick();
    cancelled(result); assert.equal(immediate, true); assert.equal(calls, before);
    if (stage === 'metadata') assert.equal(calls, 0); else assert.equal(transportSignal.aborted, true);
  });
}

for (const stage of ['create-metadata', 'config-token', 'config']) {
  test(`legacy fallback cancellation during ${stage} stops subsequent stages`, async () => {
    const hold = gate(), controller = new AbortController(), calls = []; let devices = 0, holdMetadata = false;
    const h = harness({ appInfo: () => holdMetadata ? hold.promise : Promise.resolve({ platform: 'web' }), fetch: async (url, init) => {
      const route = new URL(url).pathname; calls.push(`${init.method} ${route}`);
      if (route === '/v1/devices') {
        if (init.method === 'POST') return response({ device });
        devices++;
        if (devices === 2 && stage === 'create-metadata') { holdMetadata = true; return response([]); }
        return response([device]);
      }
      if (route === '/v1/vpn/profile') return { ok: false, status: 404, text: async () => '404 page not found' };
      if (route.endsWith('/config-token')) return stage === 'config-token' ? hold.promise : response({ token: 'fixture-config-token' });
      if (route.endsWith('/config')) return hold.promise;
      throw Error(`Unexpected fallback route ${route}`);
    } });
    const result = tracked(h.load('@/vpn/profile').resolveVpnProfile('token', paid, 'de', { forceRefresh: true, signal: controller.signal }));
    await tick(); controller.abort(); await tick(); const immediate = result.done, before = calls.slice();
    hold.resolve(stage === 'create-metadata' ? {} : response({ token: 'fixture-config-token' }));
    await result.promise; await h.load('@/vpn/profileRequestQueue').runProfileRequest(async () => 'barrier');
    cancelled(result); assert.equal(immediate, true); assert.deepEqual(calls, before);
    assert.equal(h.timers.size, 0);
  });
}

test('the actual catalog Query cancellation policy suppresses failure diagnostics and retains real failures', async () => {
  const source = ts.createSourceFile('connection.ts', fs.readFileSync(path.join(root, 'src/vpn/useVpnConnection.ts'), 'utf8'), ts.ScriptTarget.Latest, true);
  let property;
  const visit = node => { if (ts.isPropertyAssignment(node) && node.name.getText(source) === 'shouldReportError') property = node; ts.forEachChild(node, visit); };
  visit(source);
  const h = harness(), errors = h.load('@/api/error');
  const code = property && ts.transpileModule(`const policy = ${property.initializer.getText(source)};`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  const shouldReportError = code && new Function('isCancelledError', 'isApiRequestCancelled', code + ';return policy;')(isCancelledError, errors.isApiRequestCancelled);
  const { createLocationCatalogRefresher } = h.load('@/vpn/locationCatalogRefresh'), query = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  const reported = [], hold = gate(); let rejected = false;
  const refresher = createLocationCatalogRefresher({ shouldReportError, onDiagnostics: event => reported.push(event),
    fetchCatalog: () => query.fetchQuery({ queryKey: ['vpn-locations'], queryFn: () => rejected ? Promise.reject(new Error('real failure')) : hold.promise }) });
  try {
    const old = tracked(refresher.refresh('startup')); await tick(); query.removeQueries({ queryKey: ['vpn-locations'] }); await old.promise;
    assert.equal(reported.length, 0);
    rejected = true; await assert.rejects(refresher.refresh('retry'), /real failure/); assert.equal(reported.length, 1); assert.equal(reported[0].outcome, 'error');
  } finally { hold.resolve([]); query.clear(); }
});


for (const stage of ['devices', 'profile', 'register']) {
  for (const status of [400, 401, 402, 403, 404, 409, 429, 500, 502, 503, 504]) {
    test(`managed preparation ${stage} HTTP ${status} cannot authorize legacy issuance`, async () => {
      const calls = [];
      const h = harness({ fetch: async (url, init) => {
        const route = new URL(url).pathname; calls.push(`${init.method} ${route}`);
        if (route === '/v1/devices') return stage === 'devices'
          ? {ok:false,status,text:async()=>JSON.stringify({code:'fixture_denial',message:'fixture denial'})}
          : response(stage === 'register' ? [] : [device]);
        if (route === '/v1/vpn/profile' || route === '/v1/devices/register') return {ok:false,status,text:async()=>JSON.stringify({code:status === 404 ? 'not_found' : 'fixture_denial',message:'fixture denial'})};
        if (route.endsWith('/config-token')) return response({token:'inert-config-token'});
        if (route.endsWith('/config')) return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
        throw Error('Unexpected managed preparation request');
      } });
      await assert.rejects(h.load('@/api/vpn').preparedTunnel('inert-token', {platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'}, {locationId:'de'}), error => error.status === status);
      assert.equal(calls.some(call => /\/config(?:-token)?$/.test(call)), false, 'a failed managed request must not start another issuance path');
      assert.equal(calls.filter(call => call === 'POST /v1/devices').length, 0);
      const readAttempts = stage === 'devices' && [429, 502, 503, 504].includes(status) ? 3 : 1;
      assert.equal(calls.filter(call => call === 'GET /v1/devices').length, readAttempts, 'fallback must not restart an already failed device lookup');
      assert.equal(h.timers.size, 0);
    });
  }
}

for (const kind of ['network', 'body', 'invalid-json', 'invalid-profile']) {
  test(`uncertain managed profile ${kind} result cannot fall back to legacy issuance`, async () => {
    const calls = [];
    const h = harness({fetch:async (url, init) => {
      const route = new URL(url).pathname; calls.push(`${init.method} ${route}`);
      if (route === '/v1/devices') return response([device]);
      if (route === '/v1/vpn/profile') {
        if (kind === 'network') throw new TypeError('network request failed');
        if (kind === 'body') return {ok:true,status:200,text:async()=>{throw new TypeError('connection reset');}};
        if (kind === 'invalid-json') return {ok:true,status:200,text:async()=>'{'};
        return response({...profile, version:'1'});
      }
      if (route.endsWith('/config-token')) return response({token:'inert-config-token'});
      if (route.endsWith('/config')) return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
      throw Error('Unexpected profile fallback request');
    }});
    await assert.rejects(h.load('@/api/vpn').preparedTunnel('inert-token', {platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'}, {locationId:'de'}));
    assert.deepEqual(calls, ['GET /v1/devices', 'GET /v1/vpn/profile']);
    assert.equal(h.timers.size, 0);
  });
}

for (const status of [404, 405, 501]) {
  test(`a confirmed legacy profile endpoint rejection HTTP ${status} retains web fallback`, async () => {
    const calls = [];
    const h = harness({ fetch:async (url, init) => {
      const route = new URL(url).pathname;calls.push(`${init.method} ${route}`);
      if (route === '/v1/devices') return response([device]);
      if (route === '/v1/vpn/profile') return {ok:false,status,text:async()=>status===404?'404 page not found':status===405?'Method Not Allowed':'Not Implemented'};
      if (route.endsWith('/config-token')) return response({token:'inert-config-token'});
      if (route.endsWith('/config')) return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
      throw Error('Unexpected legacy profile request');
    }});
    const value = await h.load('@/api/vpn').preparedTunnel('inert-token', {platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'}, {locationId:'de'});
    assert.equal(value.device.id, device.id);
    assert.equal(value.config, 'Address = 10.0.0.2/32');
    assert.equal(calls.filter(call=>call==='GET /v1/vpn/profile').length,1);
    assert.equal(calls.filter(call=>call.endsWith('/config-token')).length,1);
    assert.equal(calls.filter(call=>call.endsWith('/config')).length,1);
  });
}


test('web without local native keys keeps server-generated legacy config without registering a native key', async () => {
  const calls = [];
  const h = harness({adapters:{'@/native/vexVpn':{supportsNativeRoutingPolicy:()=>false,getOrCreateWireGuardKeyPair:async()=>null}}, fetch:async (url, init)=>{
    const route = new URL(url).pathname;calls.push(`${init.method} ${route}`);
    if(route==='/v1/devices') return init.method==='POST'?response({device}):response([]);
    if(route.endsWith('/config-token')) return response({token:'inert-config-token'});
    if(route.endsWith('/config')) return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
    throw Error('Unexpected native-key requirement on web');
  }});
  const value=await h.load('@/api/vpn').preparedTunnel('inert-token',{platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'},{locationId:'de'});
  assert.equal(value.device.id,device.id);
  assert.equal(value.config,'Address = 10.0.0.2/32');
  assert.equal(calls.filter(call=>call==='POST /v1/devices').length,1);
  assert.equal(calls.some(call=>call==='POST /v1/devices/register'||call==='GET /v1/vpn/profile'),false);
});

test('web keeps a successful managed profile even when no local native key exists', async () => {
  const calls=[];
  const h=harness({adapters:{'@/native/vexVpn':{supportsNativeRoutingPolicy:()=>false,getOrCreateWireGuardKeyPair:async()=>null}},fetch:async(url,init)=>{
    const route=new URL(url).pathname;calls.push(`${init.method} ${route}`);
    if(route==='/v1/devices')return response([device]);
    if(route==='/v1/vpn/profile')return response({config:profile.config,version:profile.version});
    throw Error('Successful managed web profile opened a legacy path');
  }});
  const value=await h.load('@/api/vpn').preparedTunnel('inert-token',{platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'},{locationId:'de'});
  assert.equal(value.config,profile.config);assert.deepEqual(calls,['GET /v1/devices','GET /v1/vpn/profile']);
});


for (const status of [404, 405, 501]) {
  for (const body of ['{', '{}', '{"message":"generic failure"}', JSON.stringify({code:'fixture_denial',message:status===404?'404 page not found':status===405?'Method Not Allowed':'Not Implemented'})]) {
    test(`unrecognized profile endpoint HTTP ${status} body cannot authorize legacy issuance: ${body}`, async()=>{
      const calls=[];
      const h=harness({fetch:async(url,init)=>{
        const route=new URL(url).pathname;calls.push(`${init.method} ${route}`);
        if(route==='/v1/devices')return response([device]);
        if(route==='/v1/vpn/profile')return {ok:false,status,text:async()=>body};
        if(route.endsWith('/config-token'))return response({token:'inert-config-token'});
        if(route.endsWith('/config'))return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
        throw Error('Unexpected unknown profile rejection request');
      }});
      await assert.rejects(h.load('@/api/vpn').preparedTunnel('inert-token',{platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'},{locationId:'de'}),error=>error.status===status);
      assert.deepEqual(calls,['GET /v1/devices','GET /v1/vpn/profile']);
    });
  }
  for(const stage of ['devices','register']) {
    test(`unsupported response from ${stage} HTTP ${status} cannot authorize profile fallback`, async()=>{
      const calls=[];
      const unsupported=()=>({ok:false,status,text:async()=>status===404?'404 page not found':status===405?'Method Not Allowed':'Not Implemented'});
      const h=harness({fetch:async(url,init)=>{
        const route=new URL(url).pathname;calls.push(`${init.method} ${route}`);
        if(route==='/v1/devices')return stage==='devices'?unsupported():response([]);
        if(route==='/v1/devices/register')return unsupported();
        if(route.endsWith('/config-token'))return response({token:'inert-config-token'});
        if(route.endsWith('/config'))return {ok:true,status:200,text:async()=>'Address = 10.0.0.2/32'};
        throw Error('Unexpected misplaced unsupported response');
      }});
      await assert.rejects(h.load('@/api/vpn').preparedTunnel('inert-token',{platform:'web',deviceName:'Fixture',idempotencyPrefix:'fixture'},{locationId:'de'}),error=>error.status===status);
      assert.equal(calls.filter(call=>call==='GET /v1/devices').length,1);
      assert.equal(calls.some(call=>/\/config(?:-token)?$/.test(call)),false);
    });
  }
}


for (const failure of ['network', 'http503', 'malformed']) {
  for (const cancelLeader of [false, true]) {
    test(`joined profile request shares ${failure} failure without issuance replay (cancel leader=${cancelLeader})`, async () => {
      const hold = gate(), controller = new AbortController(), calls = [];
      let issued = 0;
      const h = harness({ fetch: async (url) => {
        const route = new URL(url).pathname; calls.push(route);
        if (route === '/v1/devices') return response([device]);
        if (route === '/v1/vpn/profile') {
          issued++;
          if (issued > 1) return response(profile);
          await hold.promise;
          if (failure === 'network') throw new Error('lost profile response after dispatch');
          if (failure === 'http503') return { ok: false, status: 503, headers: { get: () => null }, text: async () => '{"code":"unavailable","message":"fixture"}' };
          return { ok: true, status: 200, text: async () => '{' };
        }
        throw new Error(`Unexpected replay stage ${route}`);
      } });
      const resolver = h.load('@/vpn/profile');
      const leader = tracked(resolver.resolveVpnProfile('token', paid, 'de', {
        forceRefresh: true, shouldFetch: () => true, signal: controller.signal,
      }));
      await tick();
      assert.equal(issued, 1, 'fixture must reach actual profile dispatch');
      const follower = tracked(resolver.resolveVpnProfile('token', paid, 'de', { forceRefresh: true }));
      await tick();
      assert.equal(issued, 1, 'the foreground request must join the pending issuance');
      if (cancelLeader) controller.abort();
      hold.resolve();
      await leader.promise; await follower.promise;
      await h.load('@/vpn/profileRequestQueue').runProfileRequest(async () => 'barrier');
      assert.equal(issued, 1, 'a failed shared dispatch cannot authorize another profile issuance');
      assert.ok(follower.error, 'joined caller must observe the failed owned operation');
      if (cancelLeader) cancelled(leader);
      else assert.equal(follower.error, leader.error, 'borrowers share the original owner error');
      assert.ok(!calls.some(route => route.includes('config-token') || route.includes('rotate-key')));
      assert.equal(h.timers.size, 0);
    });
  }
}


test('a queue-refused background owner lets current foreground borrowers start before queued background work', async () => {
  const h = harness(), queue = h.load('@/vpn/profileRequestQueue'), calls = [];
  let current = true;
  const leader = tracked(queue.runProfileRequest(async () => { calls.push('stale owner body'); }, () => current, 'background', 'same'));
  const follower = tracked(queue.runProfileRequest(async () => { calls.push('foreground'); return 'owned'; }, () => true, 'foreground', 'same'));
  const secondFollower = tracked(queue.runProfileRequest(async () => { calls.push('duplicate foreground'); return 'duplicate'; }, () => true, 'foreground', 'same'));
  const background = tracked(queue.runProfileRequest(async () => { calls.push('later background'); return 'later'; }, () => true, 'background', 'other'));
  current = false;
  await leader.promise; await follower.promise; await secondFollower.promise; await background.promise;
  assert.ok(leader.error instanceof queue.ProfileRequestSupersededError);
  assert.equal(follower.value, 'owned'); assert.equal(secondFollower.value, 'owned'); assert.equal(background.value, 'later');
  assert.deepEqual(calls, ['foreground', 'later background']);
});

test('a superseded error from a started callback is not evidence that issuance never began', async () => {
  const h = harness(), queue = h.load('@/vpn/profileRequestQueue'), hold = gate();
  const failure = new queue.ProfileRequestSupersededError(); let duplicate = 0;
  const owner = tracked(queue.runProfileRequest(async () => { await hold.promise; throw failure; }, undefined, 'background', 'same'));
  await tick();
  const follower = tracked(queue.runProfileRequest(async () => { duplicate++; return 'duplicate'; }, undefined, 'foreground', 'same'));
  hold.resolve(); await owner.promise; await follower.promise;
  assert.equal(owner.error, failure); assert.equal(follower.error, failure); assert.equal(duplicate, 0);
});

test('shared issuance failure rejects stale followers and releases the queue for separate intent', async () => {
  const h = harness(), queue = h.load('@/vpn/profileRequestQueue'), hold = gate();
  const failure = new Error('uncertain owner'); let current = true, duplicate = 0;
  const owner = tracked(queue.runProfileRequest(() => hold.promise, undefined, 'background', 'same'));
  await tick();
  const stale = tracked(queue.runProfileRequest(async () => { duplicate++; }, () => current, 'foreground', 'same'));
  const live = tracked(queue.runProfileRequest(async () => { duplicate++; }, undefined, 'foreground', 'same'));
  const next = tracked(queue.runProfileRequest(async () => 'separate intent', undefined, 'foreground', 'different'));
  current = false; hold.reject(failure);
  await owner.promise; await stale.promise; await live.promise; await next.promise;
  assert.equal(owner.error, failure); assert.ok(stale.error instanceof queue.ProfileRequestSupersededError);
  assert.equal(live.error, failure); assert.equal(duplicate, 0); assert.equal(next.value, 'separate intent');
});

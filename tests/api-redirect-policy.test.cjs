const { Buffer } = require('node:buffer');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const test = require('node:test');
const ts = require('typescript');
const { QueryClient } = require('@tanstack/react-query');
const nativeFetch = globalThis.fetch;

// Load actual API modules; only platform metadata and the installed Expo native
// boundary are adapted. A separate global fetch detects an accidental fallback.
function client(fetch, baseURL = 'https://fixture.example.test', globalFetch = fetch, useRNFetch, platform = 'android') {
  const modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name).exports;
    const module = { exports: {} };
    modules.set(name, module);
    const filename = path.join(__dirname, '../src/api', name + '.ts');
    const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const requireFixture = id => {
      if (id === 'expo/fetch') return { fetch };
      if (id === 'react-native') return { Platform: { OS: platform, Version: 36 } };
      if (id === '@/native/appInfo') return {
        getAppInfo: async () => ({ platform: 'android', version: '1', build: '1' }),
        getOrCreateDeviceId: async () => 'fixture-installation',
      };
      if (id === '@/vpn/androidRoutingSafety') return {
        androidExperimentalRoutingEnabled: () => false, androidProfilePlatform: () => 'android',
      };
      assert.ok(['./config', './error', './apiFetch'].includes(id), 'Unexpected API module dependency');
      return load(id.slice(2));
    };
    new Function('module', 'exports', 'require', 'fetch', 'process', '__DEV__', output)(
      module, module.exports, requireFixture, globalFetch,
      { env: { EXPO_PUBLIC_VEX_API_BASE_URL: baseURL, EXPO_PUBLIC_USE_RN_FETCH: useRNFetch } }, false,
    );
    return module.exports;
  }
  return { ...load('client'), ...load('queryRetry'), ...load('error') };
}

async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address();
  assert.equal(address.address, '127.0.0.1');
  return { server, url: `http://127.0.0.1:${address.port}` };
}
async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

for (const method of ['GET', 'POST']) for (const status of [301, 302, 303, 307, 308]) for (const foreign of [false, true]) {
  test(`${method} ${status} ${foreign ? 'foreign' : 'same'} authority cannot replay headers or body`, async () => {
    let original = 0, forwarded = 0, receivedBody;
    const sink = await listen((request, response) => {
      forwarded++;
      const chunks = [];
      request.on('data', chunk => chunks.push(chunk));
      request.on('end', () => { receivedBody = Buffer.concat(chunks).toString(); response.end('followed'); });
    });
    let origin;
    try {
      origin = await listen((request, response) => {
        if (request.url.startsWith('/forwarded')) { forwarded++; request.resume(); response.end('followed'); return; }
        original++;
        request.resume();
        response.writeHead(status, { Location: `${foreign ? sink.url : origin.url}/forwarded?private=inert-fixture` });
        response.end('redirect body');
      });
      const api = client(nativeFetch, origin.url + '/prefix');
      const failure = await api.rawRequest('/v1/action', {
        method, accessToken: 'fixture-token', idempotencyKey: 'fixture-key',
        ...(method === 'POST' ? { body: { fixture: 'synthetic-private-body' } } : {}),
      }).then(() => null, error => error);
      assert.equal(original, 1);
      assert.equal(forwarded, 0, 'No request may reach the redirect target');
      assert.equal(receivedBody, undefined);
      assert.ok(failure instanceof Error);
      assert.equal(failure.code, 'api_redirect_blocked');
      assert.equal(failure.status, status);
      assert.equal(failure.message.includes('inert-fixture'), false);
    } finally {
      if (origin) await close(origin.server);
      await close(sink.server);
    }
  });
}

for (const flag of ['1', 'true']) {
  test(`legacy RN fetch opt-out ${flag} cannot bypass the API redirect policy`, async () => {
    let calls = 0;
    const api = client(async (_url, init) => { calls++; assert.equal(init.redirect, 'manual'); return { ok: true, status: 200, text: async () => '{}' }; },
      undefined, () => { throw new Error('legacy RN fetch must not run'); }, flag);
    assert.equal(await api.rawRequest('/v1/devices'), '{}');
    assert.equal(calls, 1);
  });
}

for (const [platform, flag] of [['android', undefined], ['web', '1']]) {
  test(`${platform} retains global fetch instrumentation`, async () => {
    let calls = 0, observed = 0;
    const sdk = async (_url, init) => { calls++; assert.equal(init.redirect, 'manual'); return { ok: true, status: 200, text: async () => '{}' }; };
    const wrapped = async (url, init) => { observed++; return sdk(url, init); };
    const api = client(sdk, undefined, wrapped, flag, platform);
    assert.equal(await api.rawRequest('/v1/devices'), '{}');
    assert.equal(calls, 1);
    assert.equal(observed, 1);
  });
}

for (const status of [0, 301, 307]) {
  test(`outer Query cannot retry blocked redirect ${status}`, async () => {
    let calls = 0, reads = 0, signal;
    const api = client(async (_url, init) => {
      calls++; signal = init.signal;
      return { ok: false, status, type: status === 0 ? 'opaqueredirect' : 'basic', text: async () => { reads++; return 'redirect body'; } };
    });
    const query = new QueryClient({ defaultOptions: { queries: { retry: api.createApiQueryRetry(2), retryDelay: 0, gcTime: 0 } } });
    try {
      await assert.rejects(query.fetchQuery({ queryKey: ['redirect'], queryFn: () => api.rawRequest('/v1/devices') }), error => error.code === 'api_redirect_blocked');
      assert.equal(calls, 1);
      assert.equal(reads, 0);
      assert.equal(signal.aborted, true, 'The rejected response must retire its native request');
    } finally { query.clear(); }
  });
}

for (const status of [200, 400]) {
  test(`completed HTTP ${status} retires the owned request signal`, async () => {
    let signal, initSeen;
    const api = client(async (_url, init) => {
      signal = init.signal; initSeen = init;
      return { ok: status === 200, status, text: async () => status === 200 ? '{}' : '{"code":"fixture","message":"rejected"}' };
    });
    if (status === 200) assert.equal(await api.rawRequest('/v1/devices', { accessToken: 'fixture-token', headers: { 'X-Fixture': 'one' } }), '{}');
    else await assert.rejects(api.rawRequest('/v1/devices'), error => error.status === 400 && error.code === 'fixture');
    assert.equal(signal.aborted, true);
    assert.equal(initSeen.redirect, 'manual');
    if (status === 200) { assert.equal(initSeen.headers.Authorization, 'Bearer fixture-token'); assert.equal(initSeen.headers['X-Fixture'], 'one'); }
  });
}

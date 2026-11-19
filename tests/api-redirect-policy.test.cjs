const { Buffer } = require('node:buffer');
const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');
const { QueryClient } = require('@tanstack/react-query');
const nativeFetch = globalThis.fetch;

// Load actual API modules; only platform metadata and the installed Expo native
// boundary are adapted. A separate global fetch detects an accidental fallback.
function client(fetch, baseURL = 'http://localhost:3011', globalFetch = fetch, useRNFetch, platform = 'android') {
  const nativeRequests = new Map();
  const local = baseURL !== 'http://localhost:3011';
  // Model native no-replay ABI separately; fixture sockets are loopback only.
  const native = {
    apiMutationNoReplay: true,
    async requestApiMutation(id, url, method, headers, body) {
      const controller = new AbortController(); nativeRequests.set(id, controller);
      try {
        assert.ok(url.startsWith('https://api.vexguard.app/v1/'));
        assert.equal(new URL(baseURL).hostname, '127.0.0.1');
        const response = await nativeFetch(new URL(new URL(url).pathname, baseURL), {
          method, headers, body, signal: controller.signal, redirect: 'manual',
        });
        return { status: response.status, body: await response.text(), headers: Object.fromEntries(response.headers) };
      } finally { nativeRequests.delete(id); }
    },
    cancelApiMutation(id) { nativeRequests.get(id)?.abort(); },
  };
  const transport = async (url, init) => {
    if (!local) return fetch(url, init);
    if (new URL(url).pathname === '/v1/billing/plans') {
      assert.equal(init.method, 'GET'); assert.deepEqual(init.headers, { Accept: 'application/json' });
      return { ok: true, status: 200, text: async () => '[]' };
    }
    try { return await fetch(new URL(new URL(url).pathname, baseURL), init); }
    catch (error) {
      // Node exposes the redirect rejection in cause; Expo reports it in message.
      if (error.cause?.message?.includes('redirect')) throw new Error('fetch failed: Redirect is not allowed');
      throw error;
    }
  };
  const load = require('./helpers/real-source-loader.cjs')({
    fetch: globalFetch, expoFetch: transport, platform, native: local ? native : {},
    env: { EXPO_PUBLIC_USE_RN_FETCH: useRNFetch, ...(local ? {} : { EXPO_PUBLIC_VEX_API_BASE_URL: baseURL }) },
  });
  return { ...load('@/api/client'), ...load('@/api/queryRetry'), ...load('@/api/error') };
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
      const api = client(nativeFetch, origin.url);
      const failure = await api.rawRequest('/v1/action', {
        method, accessToken: 'fixture-token', idempotencyKey: 'fixture-key',
        ...(method === 'POST' ? { body: { fixture: 'synthetic-private-body' } } : {}),
      }).then(() => null, error => error);
      assert.equal(original, 1);
      assert.equal(forwarded, 0, 'No request may reach the redirect target');
      assert.equal(receivedBody, undefined);
      assert.ok(failure instanceof Error);
      assert.equal(failure.code, method === 'POST' ? 'api_redirect_blocked' : 'unsafe_redirect');
      assert.equal(failure.status, method === 'POST' ? status : undefined);
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
    const api = client(async (_url, init) => { calls++; assert.equal(init.redirect, 'error'); return { ok: true, status: 200, text: async () => '{}' }; },
      undefined, () => { throw new Error('legacy RN fetch must not run'); }, flag);
    assert.equal(await api.rawRequest('/v1/devices'), '{}');
    assert.equal(calls, 1);
  });
}

for (const [platform, flag] of [['android', undefined], ['web', '1']]) {
  test(`${platform} uses its designated fetch boundary`, async () => {
    let calls = 0, observed = 0;
    const sdk = async (_url, init) => { calls++; assert.equal(init.redirect, 'error'); return { ok: true, status: 200, text: async () => '{}' }; };
    const wrapped = async (url, init) => { observed++; return sdk(url, init); };
    const api = client(sdk, undefined, wrapped, flag, platform);
    assert.equal(await api.rawRequest('/v1/devices'), '{}');
    assert.equal(calls, 1);
    assert.equal(observed, platform === 'web' ? 1 : 0);
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
    assert.equal(initSeen.redirect, 'error');
    if (status === 200) { assert.equal(initSeen.headers.Authorization, 'Bearer fixture-token'); assert.equal(initSeen.headers['X-Fixture'], 'one'); }
  });
}

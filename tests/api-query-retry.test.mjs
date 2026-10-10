import assert from 'node:assert/strict';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { QueryClient } from '@tanstack/react-query';
import { ApiRequestError, isMaintenanceStatus, normalizeApiRequestError } from '../src/api/error.ts';
import { createApiQueryRetry } from '../src/api/queryRetry.ts';

function queryClient(maxRetries = 1) {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: createApiQueryRetry(maxRetries), retryDelay: 0, gcTime: 0 },
    },
  });
}

for (const error of [
  new ApiRequestError('slow down', { status: 429, retryAfterMs: 60000 }),
  new ApiRequestError('slow down', { status: 429 }),
  new ApiRequestError('temporarily unavailable', { status: 500, retryAfterMs: 60000 }),
  ...[400, 401, 403, 404, 409, 422].map(status => new ApiRequestError('rejected', { status })),
  new ApiRequestError('offline', { code: 'network_unavailable' }),
  new ApiRequestError('deadline', { code: 'request_timeout' }),
  ...[502, 503, 504].map(status => new ApiRequestError('maintenance', { status })),
]) {
  test(`query never restarts rejected API work: ${error.status ?? error.code}, retryAfter=${error.retryAfterMs}`, async () => {
    const client = queryClient(2);
    let calls = 0;
    try {
      await assert.rejects(client.fetchQuery({
        queryKey: ['api-fixture'],
        queryFn: async () => { calls++; throw error; },
      }), actual => actual === error);
      assert.equal(calls, 1);
    } finally {
      client.clear();
    }
  });
}

for (const retries of [1, 2]) {
  for (const error of [new Error('temporary local preparation failure'), new ApiRequestError('server error', { status: 500 }), new ApiRequestError('server timed out', { status: 408 })]) {
    test(`query retains ${retries} configured retries for ${error.status ?? 'local failure'}`, async () => {
      const client = queryClient(retries);
      let calls = 0;
      try {
        const value = await client.fetchQuery({
          queryKey: ['api-fixture'],
          queryFn: async () => {
            if (++calls <= retries) throw error;
            return 'recovered';
          },
        });
        assert.equal(value, 'recovered');
        assert.equal(calls, retries + 1);
      } finally {
        client.clear();
      }
    });
  }
  test(`persistent local failure stops after ${retries} configured retries`, async () => {
    const client = queryClient(retries);
    let calls = 0;
    try {
      await assert.rejects(client.fetchQuery({
        queryKey: ['local-fixture'],
        queryFn: async () => { calls++; throw new Error('still unavailable'); },
      }), /still unavailable/);
      assert.equal(calls, retries + 1);
    } finally {
      client.clear();
    }
  });
}

// Exercise the real HTTP layer together with TanStack Query: a Retry-After
// longer than the request deadline must remain a single fetch end to end.
const source = stripTypeScriptTypes(fs.readFileSync('src/api/client.ts', 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
function rawClient(fetch) {
  return new Function('fetch', 'ApiRequestError', 'isMaintenanceStatus', 'normalizeApiRequestError', 'getAppInfo', 'getOrCreateDeviceId', 'Platform', 'androidExperimentalRoutingEnabled', 'androidProfilePlatform', source + '; return rawRequest;')(
    fetch, ApiRequestError, isMaintenanceStatus, normalizeApiRequestError, async () => ({}), async () => 'fixture', { OS: 'android' }, () => false, () => 'android',
  );
}

test('outer query retries cannot bypass a server cooldown beyond the HTTP deadline', async () => {
  const client = queryClient(2);
  let requests = 0;
  const rawRequest = rawClient(async () => {
    requests++;
    return { ok: false, status: 429, headers: { get: () => '60' }, text: async () => '{"message":"slow down"}' };
  });
  try {
    await assert.rejects(client.fetchQuery({
      queryKey: ['devices'],
      queryFn: () => rawRequest('/v1/devices', { timeout: 1000 }),
    }), error => error.status === 429 && error.retryAfterMs === 60000);
    assert.equal(requests, 1);
  } finally {
    client.clear();
  }
});

test('outer query does not restart an exhausted HTTP request deadline', async () => {
  const client = queryClient();
  let requests = 0;
  const rawRequest = rawClient(() => { requests++; return new Promise(() => {}); });
  try {
    await assert.rejects(client.fetchQuery({
      queryKey: ['devices'],
      queryFn: () => rawRequest('/v1/devices', { timeout: 100 }),
    }), error => error.code === 'request_timeout');
    assert.equal(requests, 1);
  } finally {
    client.clear();
  }
});

test('outer query does not multiply exhausted HTTP transport retries', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
  const client = queryClient(2);
  let requests = 0;
  const rawRequest = rawClient(async () => { requests++; throw new TypeError('Failed to fetch'); });
  try {
    const rejected = assert.rejects(client.fetchQuery({
      queryKey: ['devices'],
      queryFn: () => rawRequest('/v1/devices', { timeout: 5000 }),
    }), error => error.code === 'network_unavailable');
    await settle();
    assert.equal(requests, 1);
    t.mock.timers.tick(600); await settle();
    assert.equal(requests, 2);
    t.mock.timers.tick(1200); await settle();
    await rejected;
    t.mock.timers.tick(5000); await settle();
    assert.equal(requests, 3);
  } finally {
    client.clear();
  }
});

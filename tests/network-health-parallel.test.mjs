import assert from 'node:assert/strict';
import test from 'node:test';
import { probeNetworkHealth } from '../src/vpn/networkHealthProbe.ts';
import { assessVpnAutopilotIssue } from '../src/vpn/vpnAutopilotAssessment.ts';

const tick = () => new Promise((resolve) => setImmediate(resolve));
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};

test('endpoint and HTTPS probes start without waiting for each other', async () => {
  const endpoint = deferred();
  const https = deferred();
  const started = [];
  const result = probeNetworkHealth({
    apiBaseUrl: 'https://fixture.example', endpoint: 'fixture.example:443',
    measureEndpointLatency: () => { started.push('endpoint'); return endpoint.promise; },
    fetchImpl: () => { started.push('https'); return https.promise; },
  });
  await tick();
  try {
    assert.deepEqual(started.sort(), ['endpoint', 'https']);
  } finally {
    endpoint.resolve(12);
    https.resolve({ ok: true, status: 204 });
    await result;
  }
});

test('stalled endpoint does not hold a successful HTTPS probe past the shared deadline', async () => {
  const result = await Promise.race([
    probeNetworkHealth({
      apiBaseUrl: 'https://fixture.example', endpoint: 'fixture.example:443', timeoutMs: 25,
      measureEndpointLatency: () => new Promise(() => {}),
      fetchImpl: async () => ({ ok: true, status: 204 }),
    }),
    new Promise((_, reject) => setTimeout(() => reject(new Error('probe never completed')), 250)),
  ]);
  assert.equal(result.httpsOk, true);
  assert.equal(result.dnsOk, undefined);
  assert.equal(result.endpointProbeError, 'endpoint_probe_timeout');
});

test('HTTPS implementation ignoring abort still has a bounded result', async () => {
  let signal;
  const result = await Promise.race([
    probeNetworkHealth({
      apiBaseUrl: 'https://fixture.example', timeoutMs: 25,
      fetchImpl: async (_url, options) => { signal = options.signal; return new Promise(() => {}); },
    }),
    new Promise((_, reject) => setTimeout(() => reject(new Error('probe never completed')), 250)),
  ]);
  assert.equal(signal.aborted, true);
  assert.equal(result.httpsOk, false);
  assert.equal(result.httpsProbeError, 'https_probe_timeout');
});

test('missing endpoint latency does not fabricate a DNS failure', async () => {
  const probe = await probeNetworkHealth({
    apiBaseUrl: 'https://fixture.example', endpoint: '192.0.2.1:443',
    measureEndpointLatency: async () => null,
    fetchImpl: async () => ({ ok: true, status: 204 }),
  });
  assert.equal(probe.dnsOk, undefined);
  assert.equal(probe.endpointLatencyMs, null);
  assert.notEqual(assessVpnAutopilotIssue({ probe }).cause, 'dns');
});

test('only explicit DNS errors report DNS failure', async () => {
  for (const [message, dnsOk] of [['lookup failed', false], ['connection refused', undefined]]) {
    const probe = await probeNetworkHealth({
      apiBaseUrl: 'https://fixture.example', endpoint: 'fixture.example:443',
      measureEndpointLatency: async () => { throw new Error(message); },
      fetchImpl: async () => ({ ok: true, status: 204 }),
    });
    assert.equal(probe.dnsOk, dnsOk);
    assert.equal(probe.httpsOk, true);
  }
});

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const test = require('node:test');

const root = path.join(__dirname, '..');
const ts = createRequire(path.join(root, 'package.json'))('typescript');
const tick = () => new Promise(setImmediate);
const now = Date.parse('2026-10-20T12:00:00Z');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function policy(id = 'prepared', expires = now + 60_000) {
  return {
    policy_version: id,
    expires_at: new Date(expires).toISOString(),
    probe: { max_candidates: 2, failure_threshold: 2, quarantine_ms: 30_000, failback_hold_ms: 120_000 },
    candidates: [{ id, path_kind: 'relay', device_id: 'fixture-device', protocol: 'amneziawg',
      location_id: 'fixture', node_id: 'fixture-node', endpoint: '203.0.113.2:443',
      priority: 10, health_score: 100, expires_at: new Date(expires).toISOString() }],
  };
}

function saved(owner, policyRaw) {
  return JSON.stringify({ owner, policyRaw, snapshot: { routes: {}, preferredByDevice: {} } });
}

const profile = {
  locationId: 'fixture', device: { id: 'fixture-device', nodeId: 'fixture-node', protocol: 'amneziawg' },
  config: '[Interface]\nHeaderProtectionKey = FIXTURE\n[Peer]\nEndpoint = 192.0.2.1:443\n',
};

// Execute the real runtime, parser, route engine and endpoint fallback. Only
// native storage, HTTP and the clock are isolated; no real VPN or API is used.
function fixture(stored = null) {
  const requests = [];
  const reads = [];
  const writes = [];
  const heldReads = [];
  let currentTime = now;
  const modules = new Map();
  const adapters = {
    '@/native/secureStore': {
      getItemAsync: async (key) => {
        reads.push(key);
        return heldReads.length ? heldReads.shift().promise : stored;
      },
      setItemAsync: async (_key, value) => { writes.push(JSON.parse(value)); stored = value; },
    },
    '@/api/vexApi': { vpnResiliencePolicy: (token) => {
      const response = deferred();
      requests.push({ token, ...response });
      return response.promise;
    } },
  };
  function load(file) {
    if (modules.has(file)) return modules.get(file).exports;
    const module = { exports: {} };
    modules.set(file, module);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText;
    vm.runInNewContext(code, {
      module, exports: module.exports,
      require: (id) => {
        if (adapters[id]) return adapters[id];
        assert.ok(id.startsWith('.'), `Unexpected import ${id}`);
        return load(path.resolve(path.dirname(file), `${id}.ts`));
      },
      Date: class extends Date { static now() { return currentTime; } },
    }, { filename: file });
    return module.exports;
  }
  return {
    runtime: load(path.join(root, 'src/vpn/dynamicRouteRuntime.ts')).dynamicRouteRuntime,
    requests, reads, writes,
    holdRead: () => { const read = deferred(); heldReads.push(read); return read; },
    clock: (value) => { currentTime = value; },
    routeIds: () => load(path.join(root, 'src/vpn/dynamicRouteRuntime.ts')).dynamicRouteRuntime
      .attempts(profile).map((attempt) => attempt.candidate?.id).filter(Boolean).join(','),
  };
}

test('a slow optional policy response does not hold connection preparation', async () => {
  const f = fixture();
  let prepared = false;
  void f.runtime.prepare('owner', 'token').then(() => { prepared = true; });
  await tick();
  assert.equal(f.requests.length, 1);
  assert.equal(prepared, true, 'Connect must be ready while the HTTP response is still pending');
  assert.equal(f.runtime.attempts(profile)[0].profile.config, profile.config);
  f.requests[0].resolve(policy());
  await tick();
  assert.equal(f.routeIds(), 'prepared');
});

test('a valid persisted policy is ready immediately and makes no HTTP request', async () => {
  const f = fixture(saved('owner', policy('cached')));
  await f.runtime.prepare('owner', 'token');
  assert.equal(f.routeIds(), 'cached');
  assert.equal(f.requests.length, 0);
});

test('foreground and Connect share cache hydration before considering a fetch', async () => {
  const f = fixture();
  const read = f.holdRead();
  const foreground = f.runtime.prepare('owner', 'token');
  const connect = f.runtime.prepare('owner', 'token');
  await tick();
  assert.equal(f.reads.length, 1);
  assert.equal(f.requests.length, 0, 'Do not race a valid cache with the API');
  read.resolve(saved('owner', policy('cached')));
  await Promise.all([foreground, connect]);
  assert.equal(f.requests.length, 0);
  assert.equal(f.routeIds(), 'cached');
});

test('repeated preparation coalesces an unfinished fetch beyond the retry interval', async () => {
  const f = fixture();
  void f.runtime.prepare('owner', 'token');
  await tick();
  f.clock(now + 35_000);
  void f.runtime.prepare('owner', 'token');
  await tick();
  assert.equal(f.requests.length, 1);
  f.requests[0].resolve(policy());
  await tick();
  assert.equal(f.routeIds(), 'prepared');
});

test('API failure and an expired policy leave the signed profile usable without delay', async () => {
  const f = fixture(saved('owner', policy('expired', now - 1)));
  let prepared = false;
  void f.runtime.prepare('owner', 'token').then(() => { prepared = true; });
  await tick();
  assert.equal(prepared, true);
  assert.equal(f.routeIds(), '');
  f.requests[0].reject(new Error('Offline fixture'));
  await tick();
  await f.runtime.prepare('owner', 'token');
  assert.equal(f.requests.length, 1, 'Keep the existing retry cooldown');
  assert.equal(f.runtime.attempts(profile)[0].profile.config, profile.config);
});

test('late HTTP from an earlier login cannot replace the current same-account policy', async () => {
  const f = fixture();
  let oldCurrent = true;
  void f.runtime.prepare('owner', 'old-token', () => oldCurrent);
  await tick();
  oldCurrent = false;
  void f.runtime.prepare('owner', 'new-token', () => true);
  await tick();
  assert.equal(f.requests.length, 2);
  f.requests[1].resolve(policy('new-login'));
  await tick();
  f.requests[0].resolve(policy('old-login'));
  await tick();
  assert.equal(f.routeIds(), 'new-login');
  assert.ok(f.writes.every((value) => value.policyRaw.policy_version === 'new-login'));
});

test('switching A to B to A rejects an old cache hydration for A', async () => {
  const f = fixture();
  const first = f.holdRead();
  void f.runtime.prepare('A', 'a1');
  await tick();
  const second = f.holdRead();
  void f.runtime.prepare('B', 'b1');
  await tick();
  second.resolve(saved('B', policy('b-cache')));
  await tick();
  const third = f.holdRead();
  void f.runtime.prepare('A', 'a2');
  await tick();
  third.resolve(saved('A', policy('current-a')));
  await tick();
  first.resolve(saved('A', policy('obsolete-a')));
  await tick();
  assert.equal(f.routeIds(), 'current-a');
});

test('an invalidated session cannot publish its policy or start another request', async () => {
  const f = fixture();
  let current = true;
  void f.runtime.prepare('owner', 'token', () => current);
  await tick();
  current = false;
  f.requests[0].resolve(policy('obsolete'));
  await tick();
  assert.equal(f.routeIds(), '');
  assert.equal(f.writes.length, 0);
  await f.runtime.prepare('owner', 'token', () => false);
  assert.equal(f.requests.length, 1);
});

test('an old queued cache write cannot overwrite a later login after A to B to A', async () => {
  const f = fixture();
  void f.runtime.prepare('A', 'a1');
  await tick();
  const oldWriteRead = f.holdRead();
  f.requests[0].resolve(policy('obsolete-a'));
  await tick();
  void f.runtime.prepare('B', 'b1');
  await tick();
  void f.runtime.prepare('A', 'a2');
  await tick();
  assert.equal(f.requests.length, 3);
  oldWriteRead.resolve(null);
  await tick();
  assert.equal(f.writes.length, 0);
  f.requests[2].resolve(policy('current-a'));
  await tick();
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].policyRaw.policy_version, 'current-a');
});

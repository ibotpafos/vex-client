const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const test = require('node:test');

const root = process.env.CLIENT_PACKAGE_JSON || path.join(__dirname, '..', 'package.json');
const ts = createRequire(root)('typescript');
const sourcePath = process.env.DIAGNOSTICS_SOURCE || path.join(__dirname, '..', 'src', 'diagnostics', 'clientDiagnostics.ts');

// Execute the actual complete module with isolated native/API/storage adapters.
// No account, device, network, VPN, or production operation is performed.
function fixture(results) {
  let now = 1_000_000;
  let probes = 0;
  const reports = [];
  let network = { networkClass: 'cellular', generation: 'ba88893a-0bc5-4c1b-8f69-b9cce50172d0' };
  let nativeState = 'disconnected';
  let failSeed = false;
  let seedWait = null;
  let nextTimer = 0;
  const timers = new Map();
  const pure = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(path.dirname(sourcePath), 'networkObservation.ts'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText, { module: pure, exports: pure.exports });
  const modules = {
    '@/api/vexApi': {
      vexApiBaseUrl: 'https://fixture.example',
      submitClientDiagnostics: async (_token, report) => {
        if (failSeed && report.reason === 'network_before_connect') throw new Error('Offline fixture');
        reports.push(report);
        if (report.reason === 'network_before_connect' && seedWait) await seedWait;
        return { id: 'fixture-observation' };
      },
    },
    '@/native/appInfo': { getAppInfo: async () => ({ platform: 'android', version: '1.0.64', build: '1006472' }) },
    '@/native/secureStore': {
      getItemAsync: async () => null,
      deleteItemAsync: async () => undefined,
      setItemAsync: async () => { throw new Error('Unexpected queue write'); },
    },
    '@/native/vexVpn': {
      readNativeVpnDiagnostics: async () => ({}),
      readVpnNetworkObservation: async () => network,
      getVpnStatus: async () => ({ state: nativeState }),
      measureEndpointLatency: async () => { throw new Error('Unexpected native latency call'); },
    },
    '@/vpn/networkHealthProbe': {
      probeNetworkHealth: async () => {
        const result = results[probes++];
        assert.ok(result, 'Unexpected additional network probe');
        return result;
      },
    },
    './networkObservation': pure.exports,
    './otaProvenance': {
      getOtaProvenance: () => ({
        ota_update_id: '45f1420d-43a7-4c7d-9412-2e7fd4236ad4',
        ota_runtime_version: '1.0.64',
        ota_is_embedded_launch: true,
        ota_is_emergency_launch: true,
      }),
    },
  };
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  vm.runInNewContext(code, {
    module, exports: module.exports,
    require: (id) => { assert.ok(modules[id], `Unexpected import ${id}`); return modules[id]; },
    Date: class extends Date { static now() { return now; } },
    setTimeout: (callback) => { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout: (id) => timers.delete(id),
    fetch: () => { throw new Error('Real network forbidden'); },
  }, { filename: sourcePath });
  return {
    reports,
    capture: (token = 'TOKEN', device = 'fixture-device', isCurrent) => module.exports.prepareClientNetworkDiagnostics(token, device, isCurrent),
    holdSeed: (promise) => { seedWait = promise; },
    expireCapture: () => { for (const callback of [...timers.values()]) callback(); },
    network: (generation) => { network = { ...network, generation }; },
    nativeState: (state) => { nativeState = state; },
    failSeed: () => { failSeed = true; },
    probes: () => probes,
    clock: (value) => { now = value; },
    upload: (state, handshake, endpoint = 'HOST:443', samples) => module.exports.uploadClientDiagnostics('TOKEN', {
      reason: 'fixture', status: 'ok', endpoint, deviceId: 'fixture-device',
      vpnStatus: { state, latestHandshakeEpochMillis: handshake },
      samples,
    }),
  };
}

test('unknown DNS preserves the legacy boolean wire contract and unmeasured sample', async () => {
  const f = fixture([{ httpsOk: true }]);
  await f.upload('connected', 100);
  assert.equal(f.reports[0].dnsOk, true);
  assert.equal(f.reports[0].samples.network_probe.dnsOk, undefined);
  assert.equal(f.reports[0].httpsOk, true);
});

test('a prepared observation is reused at Connect without a second server seed', async () => {
  const f = fixture([]);
  await f.capture();
  await f.capture();
  assert.equal(f.reports.length, 1);
});

test('background preparation and Connect share one in-flight observation', async () => {
  const f = fixture([]);
  let release;
  f.holdSeed(new Promise(resolve => { release = resolve; }));
  const background = f.capture();
  const connect = f.capture();
  let backgroundSettled = false;
  void background.then(() => { backgroundSettled = true; });
  await new Promise(setImmediate);
  assert.equal(f.reports.length, 1);
  assert.equal(backgroundSettled, false);
  release();
  await Promise.all([background, connect]);
});

test('prepared observation is refreshed for a changed network, account or device', async () => {
  const f = fixture([]);
  await f.capture();
  f.network('cd88893a-0bc5-4c1b-8f69-b9cce50172d0');
  await f.capture();
  await f.capture('OTHER_TOKEN');
  await f.capture('OTHER_TOKEN', 'other-fixture-device');
  assert.equal(f.reports.length, 4);
});

test('a superseded session cannot seed an observation or reuse a prepared one', async () => {
  const f = fixture([{ httpsOk: true }]);
  await f.capture('TOKEN', 'fixture-device', () => false);
  assert.equal(f.reports.length, 0);
  let current = true;
  let release;
  f.holdSeed(new Promise(resolve => { release = resolve; }));
  const pending = f.capture('TOKEN', 'fixture-device', () => current);
  await new Promise(setImmediate);
  current = false;
  release();
  await pending;
  await f.upload('connected', 100);
  assert.equal(f.reports.at(-1).networkObservationId, undefined);
});

test('stalled optional preparation expires and a late result cannot replace a newer capture', async () => {
  const f = fixture([{ httpsOk: true }]);
  let release;
  f.holdSeed(new Promise(resolve => { release = resolve; }));
  const pending = f.capture();
  await new Promise(setImmediate);
  f.expireCapture();
  assert.equal(await Promise.race([pending.then(() => true), new Promise(resolve => setImmediate(() => resolve(false)))]), true);
  f.holdSeed(null);
  f.network('cd88893a-0bc5-4c1b-8f69-b9cce50172d0');
  await f.capture();
  release();
  await new Promise(setImmediate);
  await f.upload('connected', 100);
  assert.equal(f.reports.at(-1).networkObservationId, 'fixture-observation');
});

test('a VPN started during optional capture cannot become an underlay observation', async () => {
  const f = fixture([{ httpsOk: true }]);
  let release;
  f.holdSeed(new Promise(resolve => { release = resolve; }));
  const pending = f.capture();
  await new Promise(setImmediate);
  f.nativeState('connected');
  release();
  await pending;
  await f.upload('connected', 100);
  assert.equal(f.reports.at(-1).networkObservationId, undefined);
});

test('a prepared receipt cannot survive its owning login operation', async () => {
  const f = fixture([{ httpsOk: true }]);
  let current = true;
  await f.capture('TOKEN', 'fixture-device', () => current);
  current = false;
  await f.upload('connected', 100);
  assert.equal(f.reports.at(-1).networkObservationId, undefined);
  await f.capture('TOKEN', 'fixture-device', () => true);
  assert.equal(f.reports.filter(report => report.reason === 'network_before_connect').length, 2);
});

test('diagnostics attach OTA rollback provenance without a raw emergency reason', async () => {
  const f = fixture([{ httpsOk: true }]);
  await f.upload('connected', 100, 'HOST:443', { ota_is_embedded_launch: false });
  assert.deepEqual(JSON.parse(JSON.stringify({
    ota_update_id: f.reports[0].samples.ota_update_id,
    ota_runtime_version: f.reports[0].samples.ota_runtime_version,
    ota_is_embedded_launch: f.reports[0].samples.ota_is_embedded_launch,
    ota_is_emergency_launch: f.reports[0].samples.ota_is_emergency_launch,
  })), {
    ota_update_id: '45f1420d-43a7-4c7d-9412-2e7fd4236ad4',
    ota_runtime_version: '1.0.64',
    ota_is_embedded_launch: true,
    ota_is_emergency_launch: true,
  });
  assert.equal(JSON.stringify(f.reports[0].samples).includes('secret'), false);
});

test('diagnostics derive only allowlisted error class and stage from an existing raw error sample', async () => {
  const f = fixture([{ httpsOk: true }]);
  await f.upload('connected', 100, 'HOST:443', { connect_error: 'Network request failed for customer@example.test' });
  assert.equal(f.reports[0].samples.diagnostic_error_class, 'network');
  assert.equal(f.reports[0].samples.diagnostic_error_stage, 'native_connect');
  assert.equal(f.reports[0].samples.diagnostic_error_class.includes('customer'), false);
});

test('unknown HTTPS preserves the legacy boolean wire contract and unmeasured sample', async () => {
  const f = fixture([{}]);
  await f.upload('disconnected');
  assert.equal(f.reports[0].httpsOk, true);
  assert.equal(f.reports[0].samples.network_probe.httpsOk, undefined);
});

test('same endpoint is re-probed when VPN changes from disconnected to connected', async () => {
  const f = fixture([{ httpsOk: false }, { httpsOk: true }]);
  await f.upload('disconnected');
  await f.upload('connected', 100);
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, true);
});

test('healthy connected cache cannot hide a failure after disconnect', async () => {
  const f = fixture([{ httpsOk: true }, { httpsOk: false }]);
  await f.upload('connected', 100);
  await f.upload('disconnected');
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, false);
});

test('new native handshake invalidates the previous peer probe', async () => {
  const f = fixture([{ httpsOk: false }, { httpsOk: true }]);
  await f.upload('connected', 100);
  await f.upload('connected', 200);
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, true);
});

test('unchanged VPN context retains the bounded cache and real failure', async () => {
  const f = fixture([{ dnsOk: false, httpsOk: false }]);
  await f.upload('connected', 100);
  await f.upload('connected', 100);
  assert.equal(f.probes(), 1);
  assert.equal(f.reports[1].dnsOk, false);
  assert.equal(f.reports[1].httpsOk, false);
});

test('different endpoint gets its own current measurement', async () => {
  const f = fixture([{ httpsOk: true }, { httpsOk: false }]);
  await f.upload('connected', 100, 'HOST_A:443');
  await f.upload('connected', 100, 'HOST_B:443');
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, false);
});

test('expired cache is refreshed without extending its TTL', async () => {
  const f = fixture([{ httpsOk: true }, { httpsOk: false }]);
  await f.upload('connected', 100);
  f.clock(1_030_001);
  await f.upload('connected', 100);
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, false);
});

test('wall-clock rollback does not keep a future-dated healthy cache', async () => {
  const f = fixture([{ httpsOk: true }, { httpsOk: false }]);
  await f.upload('connected', 100);
  f.clock(999_000);
  await f.upload('connected', 100);
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[1].httpsOk, false);
});


test('pre-connect receipt follows unchanged underlay into connected reports', async () => {
  const f = fixture([{ httpsOk: true }]);
  await f.capture();
  f.nativeState('connected');
  await f.upload('connected', 100);
  assert.equal(f.reports[0].reason, 'network_before_connect');
  assert.equal(f.reports[1].networkObservationId, 'fixture-observation');
  assert.equal(f.reports[1].networkClass, 'cellular');
});

test('network handoff drops attribution and invalidates healthy cached probes', async () => {
  const f = fixture([{ httpsOk: true }, { httpsOk: false }]);
  await f.capture();
  await f.upload('connected', 100);
  f.network('cd88893a-0bc5-4c1b-8f69-b9cce50172d0');
  await f.upload('connected', 100);
  assert.equal(f.probes(), 2);
  assert.equal(f.reports[2].networkObservationId, undefined);
  assert.equal(f.reports[2].httpsOk, false);
});

test('an existing VPN and offline capture cannot generate or queue an underlay seed', async () => {
  const f = fixture([{ httpsOk: true }]);
  f.nativeState('connected');
  await f.capture();
  assert.equal(f.reports.length, 0);
  f.nativeState('disconnected');
  f.failSeed();
  await f.capture();
  await f.upload('connected', 100);
  assert.equal(f.reports.length, 1);
  assert.equal(f.reports[0].networkObservationId, undefined);
});

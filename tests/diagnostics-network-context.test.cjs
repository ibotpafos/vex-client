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
  const modules = {
    '@/api/vexApi': {
      vexApiBaseUrl: 'https://fixture.example',
      submitClientDiagnostics: async (_token, report) => reports.push(report),
    },
    '@/native/appInfo': { getAppInfo: async () => ({ platform: 'android', version: '1.0.64', build: '1006472' }) },
    '@/native/secureStore': {
      getItemAsync: async () => null,
      deleteItemAsync: async () => undefined,
      setItemAsync: async () => { throw new Error('Unexpected queue write'); },
    },
    '@/native/vexVpn': {
      readNativeVpnDiagnostics: async () => ({}),
      measureEndpointLatency: async () => { throw new Error('Unexpected native latency call'); },
    },
    '@/vpn/networkHealthProbe': {
      probeNetworkHealth: async () => {
        const result = results[probes++];
        assert.ok(result, 'Unexpected additional network probe');
        return result;
      },
    },
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
    fetch: () => { throw new Error('Real network forbidden'); },
  }, { filename: sourcePath });
  return {
    reports,
    probes: () => probes,
    clock: (value) => { now = value; },
    upload: (state, handshake, endpoint = 'HOST:443', samples) => module.exports.uploadClientDiagnostics('TOKEN', {
      reason: 'fixture', status: 'ok', endpoint,
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

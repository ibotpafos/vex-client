const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

// Reuse the auto-connect test's AST harness. Only native/API boundaries are
// mocked; the production callback and cleanup/fallback policy execute as-is.
const repo = path.resolve(__dirname, '..');
function loadPolicy(file, dependencies = {}) {
  const code = ts.transpileModule(fs.readFileSync(path.isAbsolute(file) ? file : path.join(repo, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, {
    exports, Error,
    require: (name) => {
      assert.ok(Object.hasOwn(dependencies, name), `unexpected policy import: ${name}`);
      return dependencies[name];
    },
  });
  return exports;
}
const fallback = loadPolicy('src/vpn/connectionFallback.ts');
const apiErrors = loadPolicy('src/api/error.ts');
const profileResolution = loadPolicy('src/vpn/profileResolutionFallback.ts', {
  '@/api/error': apiErrors,
  './serverSelection': { isSelectableLocation: () => true },
});
const { cleanupFailedVpnConnection } = loadPolicy('src/vpn/failedConnectionCleanup.ts', {
  './connectionFallback': fallback,
});
const parentHelper = process.env.VEX_CONNECT_FLOW_HELPER_SOURCE
  ? loadPolicy(process.env.VEX_CONNECT_FLOW_HELPER_SOURCE) : {};
const source = fs.readFileSync(process.env.VEX_CONNECT_FLOW_SOURCE || path.join(repo, 'src/vpn/useVpnConnectionFlow.ts'), 'utf8');
const root = ts.createSourceFile('useVpnConnectionFlow.ts', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let callback;
function visit(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(root) === 'connectCurrentVpn') {
    assert.equal(callback, undefined, 'connect callback must be unique');
    assert.ok(ts.isCallExpression(node.initializer));
    callback = node.initializer.arguments[0].getText(root);
  }
  ts.forEachChild(node, visit);
}
visit(root);
assert.ok(callback, 'production connect callback must exist');
const compiled = ts.transpileModule(`const connect = ${callback};`, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;
const scenarios = [
  { name: 'fresh_api_503', freshStatus: 503, cleanup: 1 },
  { name: 'fresh_access_403', freshStatus: 403, cleanup: 1 },
  { name: 'missing_fresh_then_alternate_503', freshStatus: 404, alternateStatus: 503, cleanup: 1 },
  { name: 'fresh_api_503_antileak_off', freshStatus: 503, antiLeakEnabled: false, cleanup: 1 },
  { name: 'cleanup_rejection_keeps_original_error', freshStatus: 503, cleanupRejects: true, cleanup: 1 },
  { name: 'all_transport_attempts_fail', cleanup: 1 },
  { name: 'first_attempt_succeeds', succeedsAt: 1, cleanup: 0 },
  { name: 'fresh_attempt_succeeds', succeedsAt: 2, cleanup: 0 },
  { name: 'initial_admission_keeps_existing_tunnel', admission: true, cleanup: 0 },
  { name: 'initial_profile_error_no_native_attempt', initialStatus: 401, cleanup: 0 },
  { name: 'verified_tunnel_survives_persistence_error', succeedsAt: 1, persistRejects: true, cleanup: 0 },
  ...[400, 500].flatMap(status => ['network is unreachable', 'no route to host', 'connection timed out'].map(message => ({
    name: `uncertain_fresh_${status}_${message.replaceAll(' ', '_')}`,
    freshStatus: status, freshMessage: message, uncertainFresh: true, cleanup: 1,
  }))),
  { name: 'fresh_native_failure_keeps_location_failover', succeedsAt: 3, cleanup: 0 },
];
async function run(scenario) {
  let nativeState = scenario.admission ? 'connected' : 'disconnected';
  let nativeCalls = 0;
  let resolveCalls = 0;
  let simulatedPlacementWrites = 0;
  let freshFailure;
  const resolutionLocations = [];
  const nativeEndpoints = [];
  const disconnects = [];
  const apiError = (status, message) => {
    const error = new apiErrors.ApiRequestError(message || `fixture API ${status}`, { status });
    return message ? apiErrors.normalizeApiRequestError(error) : error;
  };
  const profile = (locationId, fresh) => ({ locationId, config: 'fixture', hotProfileUsed: true, device: { id: 'fixture-device', endpoint: `${locationId}-${fresh ? 'second' : 'first'}.example.test:443` } });
  const isMissing = profileResolution.isProfileResolutionFallbackError;
  const context = {
    Date, Error,
    requireCurrentSession: () => {},
    selectedLocationId: 'old-selection', serverSelectionMode: 'auto',
    availableLocations: [{ id: 'selected' }, { id: 'alternate' }],
    chooseBestVpnLocation: () => ({ id: 'selected' }),
    profileResolutionOrder: (id) => [{ id }, ...['selected', 'alternate'].filter((v) => v !== id).map((v) => ({ id: v }))],
    explicitConnectProfileResolutionOptions: {},
    resolveConnectableVpnProfile: async (locationId, options = {}) => {
      resolveCalls++;
      resolutionLocations.push(locationId);
      if (scenario.initialStatus) throw apiError(scenario.initialStatus);
      if (locationId === 'selected' && options.forceRefresh && scenario.freshStatus) {
        if (scenario.uncertainFresh) simulatedPlacementWrites++;
        freshFailure = apiError(scenario.freshStatus, scenario.freshMessage);
        throw freshFailure;
      }
      if (locationId === 'alternate' && scenario.alternateStatus) throw apiError(scenario.alternateStatus);
      return profile(locationId, options.forceRefresh);
    },
    isProfileResolutionFallbackError: isMissing,
    resolveProfileOrSkipMissing: async (resolve) => {
      try { return await resolve(); } catch (error) { if (isMissing(error)) return null; throw error; }
    },
    Platform: { OS: 'android' }, androidVpnProfileWithinBinderBudget: () => true,
    connectProfileWithEndpointFallback: async (p) => {
      nativeCalls++;
      nativeEndpoints.push(p.device.endpoint);
      if (scenario.admission) throw Object.assign(new Error('fixture invalid config'), { code: 'VPN_CONFIG_INVALID' });
      nativeState = 'connecting';
      if (scenario.succeedsAt === nativeCalls) {
        nativeState = 'connected';
        return { profile: p, status: { state: 'connected' }, endpointAttempts: [] };
      }
      throw new Error('VPN handshake failed');
    },
    ...parentHelper, cleanupFailedVpnConnection,
    isVpnTransportFallbackError: fallback.isVpnTransportFallbackError,
    antiLeakEnabled: scenario.antiLeakEnabled !== false,
    disconnectVpn: async (options) => {
      disconnects.push(options.releaseAntiLeak);
      if (scenario.cleanupRejects) throw new Error('fixture disconnect failure');
      nativeState = 'disconnected';
    },
    session: { accessToken: 'fixture', user: { id: 'fixture-user' } }, vpnStatus: { state: 'disconnected' },
    saveHotVpnProfile: async () => {},
    uploadClientDiagnostics: async () => {}, errorMessage: (error) => error.message,
    profileEndpoint: () => undefined, clientLatencyMs: null,
    setSelectedVpnLocation: async (id) => {
      if (scenario.persistRejects) throw new Error('fixture persistence failure');
      return id;
    },
    setSelectedLocationId: () => {}, cacheProfile: () => {}, setActiveProfile: () => {},
    setVpnStatus: () => {}, reportVpnConnectEvent: () => {},
    vpnConnectTelemetry: () => ({}), vpnConnectTimingSamples: () => ({}),
  };
  vm.runInNewContext(compiled, context);
  let error;
  try { await vm.runInNewContext('connect()', context); } catch (caught) { error = caught; }
  return { name: scenario.name, nativeCalls, resolveCalls, resolutionLocations, nativeEndpoints, simulatedPlacementWrites, originalFailurePreserved: Boolean(freshFailure && error === freshFailure), disconnects, nativeState, error: error?.message ?? null };
}
(async () => {
  const results = [];
  const failures = [];
  for (const scenario of scenarios) {
    const result = await run(scenario);
    results.push(result);
    if (!process.argv.includes('--probe')) try {
      assert.equal(result.disconnects.length, scenario.cleanup, scenario.name);
      if (scenario.cleanup) assert.equal(result.disconnects[0], scenario.antiLeakEnabled === false, 'preserve anti-leak policy');
      if (scenario.freshStatus && scenario.freshStatus !== 404 && !scenario.freshMessage) assert.equal(result.error, `fixture API ${scenario.freshStatus}`, 'retain original API error');
      if (scenario.alternateStatus) assert.equal(result.error, `fixture API ${scenario.alternateStatus}`);
      if (scenario.cleanup && !scenario.cleanupRejects) assert.equal(result.nativeState, 'disconnected');
      if (scenario.succeedsAt || scenario.admission) assert.equal(result.nativeState, 'connected');
      if (scenario.initialStatus) assert.equal(result.nativeCalls, 0);
      if (scenario.admission) assert.equal(result.nativeCalls, 1, 'do not retry an admission failure');
      if (scenario.succeedsAt && !scenario.persistRejects) assert.equal(result.error, null);
      if (scenario.uncertainFresh) {
        assert.equal(result.error, scenario.freshMessage, 'retain the normalized production error');
        assert.equal(result.originalFailurePreserved, true, 'preserve the original error object');
        assert.equal(result.simulatedPlacementWrites, 1);
        assert.deepEqual(result.resolutionLocations, ['selected', 'selected'], 'do not acquire a different location after uncertain preparation');
        assert.equal(result.nativeCalls, 1, 'no native connection follows a lost acquisition response');
      }
      if (scenario.name === 'fresh_attempt_succeeds') {
        assert.deepEqual(result.nativeEndpoints, ['selected-first.example.test:443', 'selected-second.example.test:443']);
        assert.deepEqual(result.resolutionLocations, ['selected', 'selected']);
      }
      if (scenario.name === 'fresh_native_failure_keeps_location_failover') {
        assert.deepEqual(result.resolutionLocations, ['selected', 'selected', 'alternate']);
        assert.equal(result.nativeCalls, 3);
      }
    } catch (error) { failures.push({ scenario: scenario.name, error }); }
  }
  console.log(JSON.stringify({ input: 'isolated recovery/API/native fixtures', results }));
  if (failures.length) throw new AggregateError(failures.map(({ scenario, error }) => new Error(`${scenario}: ${error.message}`)), `${failures.length} recovery scenario(s) failed`);
  if (!process.argv.includes('--probe')) console.log(`CONNECT_RECOVERY_CLEANUP=PASS (${results.length} scenarios)`);
})().catch((error) => { console.error(error); process.exitCode = 1; });

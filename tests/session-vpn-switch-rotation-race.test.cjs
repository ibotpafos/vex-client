const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');

const repo = path.resolve(__dirname, '..');
function policy(file, dependencies = {}) {
  const code = ts.transpileModule(fs.readFileSync(path.join(repo, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, Error, require: name => {
    assert.ok(Object.hasOwn(dependencies, name), `unexpected policy import ${name}`);
    return dependencies[name];
  } });
  return exports;
}
const sessionOperation = policy('src/vpn/sessionOperation.ts');
const { SessionOperationSupersededError } = sessionOperation;
const { switchVpnLocation } = policy('src/vpn/serverSwitch.ts', { './sessionOperation': sessionOperation });
const rotation = policy('src/vpn/devicePskRotation.ts');
const file = 'src/vpn/useVpnConnection.ts';
const source = fs.readFileSync(path.join(repo, file), 'utf8');
const root = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let switchCallback, rotationEffect;
function visit(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(root) === 'switchConnectedVpnLocation') {
    switchCallback = node.initializer.arguments[0].getText(root);
  }
  if (ts.isCallExpression(node) && node.expression.getText(root) === 'useEffect'
      && node.arguments[0].getText(root).includes('const processPendingEvents =')) {
    rotationEffect = node.arguments[0].getText(root);
  }
  ts.forEachChild(node, visit);
}
visit(root);
assert.ok(switchCallback); assert.ok(rotationEffect);
function bind(callback, context) {
  const code = ts.transpileModule(`return (${callback});`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  return new Function(...Object.keys(context), code)(...Object.values(context));
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
const profile = locationId => ({
  locationId, source: 'local', config: '[Interface]\nPrivateKey = isolated-fixture-A',
  device: { id: 'device-A' }, profileVersion: 7,
});
const connectedStatus = { state: 'connected', rxBytes: 0, txBytes: 0 };

function switchHarness(stage, options = {}) {
  const gate = deferred(), reached = deferred(), calls = [];
  let current = true;
  const wait = async (name, value) => {
    calls.push(name);
    if (stage === name) { reached.resolve(); await gate.promise; }
    return value;
  };
  const state = { current: () => current, nativeOwner: 'A', location: 'fi', activeProfile: profile('fi'), status: connectedStatus };
  const context = {
    session: { accessToken: 'token-A', user: { id: 'A' } }, isCurrentSessionOperation: () => current,
    SessionOperationSupersededError, switchVpnLocation,
    isVpnBusy: false, vpnOperationInFlightRef: { current: false },
    selectedLocationId: 'fi', activeProfile: state.activeProfile, vpnStatusRef: { current: connectedStatus },
    queryClient: { getQueryData: () => undefined }, routingMode: 'full',
    closeRouteOverlay: () => calls.push('close-overlay'),
    setIsVpnBusy: value => calls.push(`busy:${value}`), setIsServerSwitching: value => calls.push(`switching:${value}`),
    setVpnError: value => calls.push(`error:${value}`),
    isVpnTransportFallbackError: () => !options.rollback,
    resolveConnectableVpnProfile: location => wait(`resolve:${location}`, profile(location)),
    connectProfileWithEndpointFallback: async value => {
      if (options.rollback && value.locationId === 'de') {
        calls.push('connect:de'); throw new Error('target handshake failed');
      }
      const result = await wait(`connect:${value.locationId}`, { profile: value, status: connectedStatus });
      return result;
    },
    setSelectedVpnLocation: location => wait(`persist:${location}`, location),
    cacheProfile: location => calls.push(`cache:${location}`),
    reportVpnConnectEvent: value => calls.push(`report-connect:${value.locationId}`),
    reportVpnDisconnectEvent: value => calls.push(`report-disconnect:${value.locationId}`),
    setSelectedLocationId: value => { calls.push(`publish-location:${value}`); state.location = value; },
    setActiveProfile: value => { calls.push(`publish-profile:${value?.locationId}`); state.activeProfile = value; },
    setVpnStatus: value => { calls.push('publish-status'); state.status = value; },
    playWarningHaptic: () => calls.push('warning'), playSuccessHaptic: () => calls.push('success'), playErrorHaptic: () => calls.push('failure'),
    nextVpnStatusWithState: (value, state) => ({ ...value, state }), errorMessage: error => error.message,
  };
  return {
    gate, reached, calls, state, context, run: bind(switchCallback, context),
    supersede: () => {
      current = false; state.nativeOwner = 'B'; state.location = 'nl'; state.activeProfile = profile('nl');
      context.vpnOperationInFlightRef.current = true;
    },
  };
}

for (const [stage, rollback] of [
  ['resolve:de', false], ['connect:de', false], ['persist:de', false],
  ['persist:fi', true], ['resolve:fi', true], ['connect:fi', true],
]) {
  for (const outcome of ['resolve', 'reject']) {
    test(`superseded server switch during ${stage} ${outcome} cannot roll back or publish A`, async () => {
      const h = switchHarness(stage, { rollback }); const pending = h.run('de');
      await h.reached.promise; h.supersede(); const before = h.calls.slice();
      if (outcome === 'resolve') h.gate.resolve(); else h.gate.reject(new Error('late old-account failure'));
      await pending;
      assert.deepEqual(h.calls, before, 'no old-account persistence, native attempt, cache, telemetry or UI update');
      assert.equal(h.state.activeProfile.locationId, 'nl'); assert.equal(h.state.location, 'nl');
      assert.equal(h.state.nativeOwner, 'B');
      assert.equal(h.context.vpnOperationInFlightRef.current, true, 'old finally cannot unlock B');
    });
  }
}

test('an explicit switch cancellation skips rollback even while the session guard remains current', async () => {
  const h = switchHarness('connect:de'); const pending = h.run('de');
  await h.reached.promise; h.gate.reject(new SessionOperationSupersededError()); await pending;
  assert.equal(h.calls.filter(value => value === 'resolve:de').length, 1);
  assert.ok(!h.calls.includes('persist:fi')); assert.ok(!h.calls.includes('cache:fi'));
  assert.ok(!h.calls.some(value => value.startsWith('publish-')));
});

test('a genuine target failure still reconnects and publishes the current account previous location', async () => {
  const h = switchHarness(null, { rollback: true }); await h.run('de');
  assert.ok(h.calls.includes('resolve:fi')); assert.ok(h.calls.includes('connect:fi'));
  assert.ok(h.calls.includes('cache:fi')); assert.ok(h.calls.includes('publish-profile:fi'));
  assert.equal(h.context.vpnOperationInFlightRef.current, false);
});

function rotationHarness(stage, { type = 'cutover_ready', connected = true } = {}) {
  const gate = deferred(), reached = deferred(), done = deferred(), calls = [];
  let current = true;
  const staged = { rotationId: 'rotation-A', deviceId: 'device-A', profileVersion: 7, profileDigest: 'fixture-digest', profile: profile('de') };
  const event = { event_id: 'event-A', type, rotation_id: staged.rotationId, device_id: staged.deviceId, profile_version: staged.profileVersion };
  const wait = async (name, value) => {
    calls.push(name);
    if (stage === name) { reached.resolve(); await gate.promise; }
    return value;
  };
  const state = { nativeOwner: 'A', activeProfile: profile('fi') };
  const processingRef = { current: false };
  Object.defineProperty(processingRef, 'current', {
    get() { return this.value ?? false; },
    set(value) { this.value = value; if (!value) done.resolve(); },
  });
  const context = {
    Platform: { OS: 'android' }, session: { accessToken: 'token-A', user: { id: 'A' } }, activeProfile: profile('de'),
    isConnected: connected, isCurrentSessionOperation: () => current, SessionOperationSupersededError,
    processingDevicePSKEventsRef: processingRef, vpnOperationInFlightRef: { current: false },
    pendingDevicePushEvents: () => wait('events', [event]), ...rotation,
    loadStagedDevicePSKProfile: () => wait('load', type === 'cutover_ready' ? staged : null),
    fetchStagedDevicePSKProfile: () => wait('fetch', staged), saveStagedDevicePSKProfile: () => wait('save'),
    acknowledgeStagedDevicePSKProfile: () => wait('api-ack'), clearStagedDevicePSKProfile: () => wait('clear'),
    acknowledgeDevicePushEvent: () => wait('native-ack'),
    disconnectVpn: () => wait('disconnect'),
    connectProfileWithEndpointFallback: value => wait('connect', { profile: value, status: connectedStatus }),
    setActiveProfile: value => { calls.push('publish-profile'); state.activeProfile = value; },
    cacheProfile: () => calls.push('cache'), setVpnStatus: () => calls.push('publish-status'),
    reportVpnConnectEvent: () => calls.push('report-connect'),
    submitClientDiagnosticsEvent: async () => { calls.push('diagnostics'); }, errorMessage: error => error.message,
    setInterval: () => 1, clearInterval: () => {},
  };
  const cleanup = bind(rotationEffect, context)();
  return {
    gate, reached, done, calls, state, context, cleanup,
    supersede: () => {
      current = false; state.nativeOwner = 'B'; state.activeProfile = profile('nl');
      context.vpnOperationInFlightRef.current = true;
    },
  };
}

for (const [stage, type] of [
  ['events', 'cutover_ready'], ['load', 'cutover_ready'], ['disconnect', 'cutover_ready'], ['connect', 'cutover_ready'],
  ['clear', 'cutover_ready'], ['native-ack', 'cutover_ready'],
  ['load', 'profile_updated'], ['fetch', 'profile_updated'], ['save', 'profile_updated'], ['api-ack', 'profile_updated'],
]) {
  for (const outcome of ['resolve', 'reject']) {
    test(`superseded PSK ${type} during ${stage} ${outcome} cannot disconnect, activate or publish A`, async () => {
      const h = rotationHarness(stage, { type }); await h.reached.promise;
      h.supersede(); const before = h.calls.slice();
      if (outcome === 'resolve') h.gate.resolve(); else h.gate.reject(new Error('late old-account failure'));
      await flush(); await flush();
      assert.deepEqual(h.calls, before, 'no later native/API/store/cache/UI mutations or cancellation diagnostics');
      assert.equal(h.state.nativeOwner, 'B'); assert.equal(h.state.activeProfile.locationId, 'nl');
      assert.equal(h.context.vpnOperationInFlightRef.current, true, 'old activation cannot unlock B'); h.cleanup();
    });
  }
}

test('disconnected PSK cutover cannot publish an old profile after its staged load completes', async () => {
  const h = rotationHarness('load', { connected: false }); await h.reached.promise;
  h.supersede(); const before = h.calls.slice(); h.gate.resolve(); await flush(); await flush();
  assert.deepEqual(h.calls, before); assert.equal(h.state.activeProfile.locationId, 'nl'); h.cleanup();
});

test('effect cleanup cancels a staged cutover before native disconnect in the same login', async () => {
  const h = rotationHarness('load'); await h.reached.promise; h.cleanup(); h.gate.resolve(); await h.done.promise;
  assert.ok(!h.calls.includes('disconnect')); assert.ok(!h.calls.includes('diagnostics'));
});

test('the current session still durably stages before API and native event acknowledgement', async () => {
  const h = rotationHarness(null, { type: 'profile_updated' }); await h.done.promise;
  assert.deepEqual(h.calls, ['events', 'load', 'fetch', 'save', 'api-ack', 'native-ack']); h.cleanup();
});

test('the current session still activates before clearing and acknowledging a PSK cutover', async () => {
  const h = rotationHarness(null); await h.done.promise;
  assert.deepEqual(h.calls, ['events', 'load', 'disconnect', 'connect', 'publish-profile', 'cache', 'publish-status', 'report-connect', 'clear', 'native-ack']);
  assert.equal(h.context.vpnOperationInFlightRef.current, false); h.cleanup();
});

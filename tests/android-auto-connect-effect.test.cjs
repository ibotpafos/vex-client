const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const source = fs.readFileSync(process.env.VEX_ANDROID_AUTO_CONNECT_SOURCE || path.join(__dirname, '../src/vpn/useVpnConnection.ts'), 'utf8');
const root = ts.createSourceFile('useVpnConnection.ts', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let effect;
let power;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(root) === 'useEffect' && node.getText(root).includes('getAndroidAutoConnectEnabled()')) {
    assert.equal(effect, undefined, 'auto-connect effect must be unique');
    effect = node.arguments[0].getText(root);
  }
  if (ts.isVariableDeclaration(node) && node.name.getText(root) === 'handlePowerPress') power = node.initializer.arguments[0].getText(root);
  ts.forEachChild(node, visit);
}
visit(root);
assert.ok(effect, 'auto-connect effect must exist');
assert.ok(power, 'manual power callback must exist');
const compiled = ts.transpileModule(`const effect = ${effect}; const power = ${power};`, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;

async function check({ shouldFail, cancelBeforeStart }) {
  let busy = false;
  let failureHandled = false;
  let connects = 0;
  let cleanup;
  let releasePreference;
  const preference = new Promise((resolve) => { releasePreference = resolve; });
  const context = {
    Platform: { OS: 'android' },
    isCurrentSessionOperation: () => true,
    autoConnectAttemptedRef: { current: false },
    vpnOperationInFlightRef: { current: false },
    isVpnBusy: false,
    isConnected: false,
    session: {},
    entitlementState: 'active',
    hasPaidEntitlement: () => true,
    getAndroidAutoConnectEnabled: () => preference,
    setIsVpnBusy: (value) => {
      busy = value;
      if (value) cleanup(); // The busy-state render disposes the previous effect.
    },
    setVpnError: () => {},
    setVpnStatus: () => {},
    nextVpnStatusWithState: () => {},
    connectCurrentVpn: async () => {
      connects += 1;
      if (shouldFail) throw new Error('fixture failure');
    },
    handleVpnFailure: () => { failureHandled = true; },
  };
  vm.runInNewContext(compiled, context);
  cleanup = vm.runInNewContext('effect()', context);
  if (cancelBeforeStart) cleanup();
  releasePreference(true);
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(connects, cancelBeforeStart ? 0 : 1);
  assert.equal(busy, false, 'an in-flight auto-connect must release busy after cleanup');
  assert.equal(context.vpnOperationInFlightRef.current, false);
  assert.equal(failureHandled, !cancelBeforeStart && shouldFail);
}

async function checkManualIntent({ initiallyConnected, cancelWhileConnecting = false, deferPreference = false, invokePower = true, connectBeforePower = false }) {
  let connects = 0;
  let disconnects = 0;
  let releasePreference;
  const preference = deferPreference ? new Promise((resolve) => { releasePreference = resolve; }) : Promise.resolve(true);
  const context = {
    Platform: { OS: 'android' }, autoConnectAttemptedRef: { current: false },
    isCurrentSessionOperation: () => true,
    vpnOperationInFlightRef: { current: false }, vpnConnectGenerationRef: { current: 0 },
    isVpnBusy: cancelWhileConnecting, connectionPhase: cancelWhileConnecting ? 'connecting' : 'connected',
    isConnected: initiallyConnected, isLeakBlocked: false, isKeyRotationBusy: false,
    session: {}, activeProfile: null, entitlementState: 'active', hasPaidEntitlement: () => true,
    getAndroidAutoConnectEnabled: () => preference,
    setIsVpnBusy: (value) => { context.isVpnBusy = value; }, setVpnError: () => {},
    setVpnStatus: (value) => { if (typeof value !== 'function') context.isConnected = value.state === 'connected'; },
    nextVpnStatusWithState: (_, state) => ({ state }),
    connectCurrentVpn: async () => { connects += 1; },
    disconnectVpn: async () => { disconnects += 1; return { state: 'disconnected' }; },
    disconnectedVpnStatus: () => ({ state: 'disconnected' }), getVpnStatus: async () => ({ state: 'connected' }),
    dynamicRouteRuntime: { clearActive: () => {} }, handleVpnFailure: () => {}, reportVpnDisconnectEvent: () => {},
    playWarningHaptic: () => {}, playMediumImpactHaptic: () => {}, playSuccessHaptic: () => {},
  };
  vm.runInNewContext(compiled, context);
  vm.runInNewContext('effect()', context); // startup or a pending preference read
  if (connectBeforePower) context.isConnected = true;
  if (invokePower) await vm.runInNewContext('power()', context);
  context.isConnected = false; context.isVpnBusy = false;
  vm.runInNewContext('effect()', context); // render after manual stop/cancel or an observed existing tunnel
  if (deferPreference) releasePreference(true);
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(connects, 0, 'startup auto-connect must not undo a manual stop/cancel or restart an already observed tunnel');
  assert.equal(disconnects, invokePower ? 1 : 0);
}

(async () => {
  await check({ shouldFail: false, cancelBeforeStart: false });
  await check({ shouldFail: true, cancelBeforeStart: false });
  await check({ shouldFail: false, cancelBeforeStart: true });
  await checkManualIntent({ initiallyConnected: true });
  await checkManualIntent({ initiallyConnected: true, invokePower: false });
  await checkManualIntent({ initiallyConnected: false, cancelWhileConnecting: true });
  await checkManualIntent({ initiallyConnected: false, cancelWhileConnecting: true, deferPreference: true });
  await checkManualIntent({ initiallyConnected: false, deferPreference: true, connectBeforePower: true });
  console.log('ANDROID_AUTO_CONNECT_EFFECT=PASS');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

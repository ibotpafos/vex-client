const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const source = fs.readFileSync(path.join(__dirname, '../src/vpn/useVpnConnection.ts'), 'utf8');
const root = ts.createSourceFile('useVpnConnection.ts', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let effect;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(root) === 'useEffect' && node.getText(root).includes('getAndroidAutoConnectEnabled()')) {
    assert.equal(effect, undefined, 'auto-connect effect must be unique');
    effect = node.arguments[0].getText(root);
  }
  ts.forEachChild(node, visit);
}
visit(root);
assert.ok(effect, 'auto-connect effect must exist');
const compiled = ts.transpileModule(`const effect = ${effect};`, {
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

(async () => {
  await check({ shouldFail: false, cancelBeforeStart: false });
  await check({ shouldFail: true, cancelBeforeStart: false });
  await check({ shouldFail: false, cancelBeforeStart: true });
  console.log('ANDROID_AUTO_CONNECT_EFFECT=PASS');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

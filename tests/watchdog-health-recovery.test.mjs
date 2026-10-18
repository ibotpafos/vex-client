import assert from 'node:assert/strict';
import fs from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';

const watchdogSource = stripTypeScriptTypes(fs.readFileSync('src/vpn/useNativeVpnWatchdog.ts', 'utf8'))
  .replace(/import[\s\S]*?from '[^']+';/g, '')
  .replace('export function useNativeVpnWatchdog', 'function useNativeVpnWatchdog');
const connection = fs.readFileSync('src/vpn/useVpnConnection.ts', 'utf8');
const callbackStart = connection.indexOf('  const handleNativeWatchdogHealthRecovered =');
const callbackEnd = connection.indexOf('\n\n', callbackStart);
const callbackSource = stripTypeScriptTypes(connection.slice(callbackStart, callbackEnd));
const flush = async () => { for (let i = 0; i < 50; i++) await Promise.resolve(); };

function harness() {
  const state = {healthy: false, error: null, cleared: [], recoveryAttempts: 0,
    probe: async () => ({httpsOk: false, dnsOk: false})};
  let interval, cleanup, cursor = 0;
  const slots = [];
  const onHealthRecovered = new Function('useCallback', 'setVpnError',
    callbackSource + ';return handleNativeWatchdogHealthRecovered;')(
    f => f, update => { state.error = update(state.error); });
  const stubs = {
    useCallback: f => f,
    useRef: initial => slots[cursor++] ?? (slots[cursor - 1] = {current: initial}),
    useEffect: f => { cleanup?.(); cleanup = f(); },
    Platform: {OS: 'android'}, errorMessage: String,
    setInterval: f => { interval = f; return 0; }, clearInterval: () => {},
    dynamicRouteRuntime: {recordActiveFailure: () => null}, routeTransport: () => 'awg3_direct',
    localStatusHealthReasons: status => status.state === 'connected' && status.leakProtection !== 'blocking' ? [] : ['local_status_error'],
    vpnUnexpectedDisconnectTelemetry: () => null, vpnTransportTelemetry: () => ({}),
    assessNativeTunnelHealth: () => ({healthy: state.healthy, reasons: state.healthy ? [] : ['stale']}),
    assessVpnAutopilotIssue: () => ({sample: {}, userMessage: 'DNS warning'}),
    initialRecoveryBackoffState: () => ({}), recoveryAttemptAllowed: () => true,
    resetRecoveryBackoff: () => ({}), recordRecoveryFailure: () => ({}),
    recoverVpnConnection: async () => { state.recoveryAttempts++; return {ok: false}; },
  };
  const run = new Function(...Object.keys(stubs), watchdogSource + ';return useNativeVpnWatchdog;')(...Object.values(stubs));
  let input = {enabled: true, sessionAccessToken: 'fixture-session', activeDeviceId: 'device', activeLocationId: 'de',
    activeProfile: {locationId: 'de', profileVersion: 3, device: {id: 'device'}},
    operationInFlightRef: {current: false}, failureThreshold: 1, reconnectCooldownMs: 0,
    fetchDeviceUsage: async () => [], probeHealth: () => state.probe(), submitDiagnostics: async () => {}, reportConnect: () => {},
    isCurrentLocation: () => true, onRecoveryFailed: message => { state.error = message; }, onRecoverySucceeded: () => {},
    onHealthRecovered: message => { state.cleared.push(message); onHealthRecovered(message); }};
  let watchdog;
  const render = changes => { input = {...input, ...changes}; cursor = 0; watchdog = run(input); };
  render({});
  return {state, get input() { return input; }, render, poll: () => interval(), cleanup: () => cleanup(),
    record: status => watchdog.recordNativeStatus({state: 'connected'}, status)};
}

test('a fresh healthy same-profile HTTPS probe clears only the previous watchdog warning', async () => {
  for (const otherError of [null, 'Session expired']) {
    const h = harness();
    await flush();
    assert.equal(h.state.error, 'DNS warning');
    if (otherError) h.state.error = otherError;
    h.state.healthy = true;
    h.record({state: 'connected'});
    h.state.probe = async () => ({httpsOk: true});
    h.poll(); await flush();
    assert.deepEqual(h.state.cleared, ['DNS warning']);
    assert.equal(h.state.error, otherError);
    assert.equal(h.state.recoveryAttempts, 1, 'clearing a warning must not reconnect');
    h.poll(); await flush();
    assert.equal(h.state.cleared.length, 1);
    h.cleanup();
  }
});

test('backend health cannot clear a warning without fresh HTTPS, usable DNS and connected local status', async () => {
  for (const [local, probe] of [
    [{state: 'connected'}, {httpsOk: false}],
    [{state: 'connected'}, {httpsOk: true, dnsOk: false}],
    [{state: 'connected'}, {}],
    [{state: 'disconnected'}, {httpsOk: true}],
    [{state: 'connected', leakProtection: 'blocking'}, {httpsOk: true}],
  ]) {
    const h = harness(); await flush(); h.state.healthy = true;
    h.record(local); h.state.probe = async () => probe; h.poll(); await flush();
    assert.deepEqual(h.state.cleared, []); assert.equal(h.state.error, 'DNS warning'); h.cleanup();
  }
});

test('a warning from a different device, session or profile cannot be cleared by later health', async () => {
  for (const changes of [{sessionAccessToken: 'other-session'}, {activeDeviceId: 'other-device'},
    {activeProfile: {locationId: 'de', profileVersion: 4, device: {id: 'device'}}}]) {
    const h = harness(); await flush(); h.state.healthy = true;
    h.state.probe = async () => ({httpsOk: true}); h.render(changes); h.record({state: 'connected'});
    await flush(); h.poll(); await flush(); assert.deepEqual(h.state.cleared, []); h.cleanup();
  }
});

test('an in-flight recovery probe yields to disposal, a user operation or a later local failure', async () => {
  for (const action of ['dispose', 'operation', 'local-failure']) {
    const h = harness(); await flush(); h.state.healthy = true; h.record({state: 'connected'});
    let release;
    h.state.probe = () => new Promise(resolve => { release = resolve; });
    h.poll(); await flush(); assert.equal(typeof release, 'function');
    if (action === 'dispose') h.cleanup();
    if (action === 'operation') h.input.operationInFlightRef.current = true;
    if (action === 'local-failure') h.record({state: 'error'});
    release({httpsOk: true}); await flush();
    assert.deepEqual(h.state.cleared, []); assert.equal(h.state.error, 'DNS warning'); h.cleanup();
  }
});

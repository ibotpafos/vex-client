import assert from 'node:assert/strict';
import fs from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import test from 'node:test';

// Inert characterization of the production status publisher, watchdog status
// recorder and Android listener. No React renderer, timers, native calls or API.
const connection = fs.readFileSync('src/vpn/useVpnConnection.ts', 'utf8');
const profileState = fs.readFileSync('src/vpn/useVpnProfileState.ts', 'utf8');
const helpers = fs.readFileSync('src/screens/home-screen-helpers.ts', 'utf8');
const health = stripTypeScriptTypes(fs.readFileSync('src/vpn/nativeTunnelHealth.ts', 'utf8'))
  .replace(/import[\s\S]*?from '[^']+';/g, '').replace(/\bexport /g, '');
const localStatusHealthReasons = new Function(health + ';return localStatusHealthReasons;')();
const watchdog = stripTypeScriptTypes(fs.readFileSync('src/vpn/useNativeVpnWatchdog.ts', 'utf8'))
  .replace(/import[\s\S]*?from '[^']+';/g, '').replace(/\bexport /g, '');
const declaration = (source, name) => {
  const found = source.match(new RegExp(`(?:export )?function ${name}\\([^]*?\\n\\}`));
  assert.ok(found, name);
  return stripTypeScriptTypes(found[0]).replace(/^export /, '');
};
const callback = (name, source = connection) => {
  const start = source.indexOf(`  const ${name} = useCallback(`);
  assert.notEqual(start, -1, name);
  const closing = source.slice(start).match(/\n  \}, \[[^\n]*\]\);/);
  assert.ok(closing, `${name} boundary`);
  return stripTypeScriptTypes(source.slice(start, start + closing.index + closing[0].length));
};
const listenerPosition = connection.indexOf('    return listenVpnStatusChanged((nextStatus) => {');
const listener = stripTypeScriptTypes(connection.slice(
  connection.lastIndexOf('  useEffect(() => {', listenerPosition),
  connection.indexOf('\n\n  const statusPollingRef', listenerPosition)));
const phaseStart = connection.indexOf('  const isConnected =');
const phase = stripTypeScriptTypes(connection.slice(phaseStart, connection.indexOf('  const { pulseProgress', phaseStart)));
const phaseFor = new Function('vpnStatusCore', 'isServerSwitching', 'isVpnBusy', phase + ';return connectionPhase;');
const reconciliationStart = connection.indexOf('  reconcileReleasedStatusRef.current = async () => {');
const reconciliation = stripTypeScriptTypes(connection.slice(reconciliationStart, connection.indexOf('\n\n  useEffect', reconciliationStart)));
const flush = async () => {for (let i = 0; i < 20; i++) await Promise.resolve();};

function harness() {
  const initial = {state: 'connected', transport: 'amneziawg', verified: true,
    latestHandshakeEpochMillis: Date.now(), leakProtection: 'armed', rxBytes: 100, txBytes: 200};
  const state = {core: {...initial}, error: null, native: {...initial}, read: async () => state.native, readRequests: [], sessionCurrent: true};
  const ref = {current: {...initial}};
  const operation = {current: false};
  const revision = {current: 0}, generation = {current: 0}, preferences = {current: 0}, mounted = {current: true};
  const reconcileReleasedStatusRef = {current: async () => {}};
  const activeProfileRevisionRef = {current: 0};
  let receive;
  const profile = {locationId: 'fi', profileVersion: 3, transport: 'amneziawg', device: {id: 'fixture'}};
  const pendingProfileUpdates = [];
  const profileBindings = {useCallback: f => f, isCurrentSessionOperation: () => state.sessionCurrent,
    activeProfileRevisionRef, userId: 'fixture-owner',
    vpnProfileOwnerRef: {current: {userId: 'fixture-owner', isCurrentSessionOperation: () => state.sessionCurrent}},
    setVpnProfileState: update => pendingProfileUpdates.push(update)};
  const setActiveProfile = new Function(...Object.keys(profileBindings),
    callback('setVpnProfile', profileState) + ';return setVpnProfile;')(...Object.values(profileBindings));
  const watchdogBindings = {
    useRef: current => ({current}), useCallback: f => f, useEffect: () => {},
    initialRecoveryBackoffState: () => ({}), Platform: {OS: 'android'},
    localStatusHealthReasons, vpnUnexpectedDisconnectTelemetry: () => null,
  };
  const run = new Function(...Object.keys(watchdogBindings), watchdog + ';return useNativeVpnWatchdog;')(
    ...Object.values(watchdogBindings));
  const recordNativeStatus = run({activeProfile: profile, staleHandshakeSeconds: 180, submitDiagnostics: async () => {}}).recordNativeStatus;
  const bindings = {
    useCallback: f => f, useEffect: f => f(), Platform: {OS: 'android'},
    vpnStatusRef: ref, diagnosticsSnapshotRef: {current: {}},
    publishVpnTrafficStats: () => {}, setVpnStatusCore: update => {state.core = update(state.core);},
    setVpnError: value => {state.error = value;},
    isCurrentSessionOperation: () => state.sessionCurrent, vpnOperationInFlightRef: operation, recordNativeStatus,
    vpnOperationRevisionRef: revision, vpnConnectGenerationRef: generation, preferencesRevisionRef: preferences, activeProfileRevisionRef,
    vpnMountedRef: mounted, selectedLocationIdRef: {current: 'fi'}, reconcileReleasedStatusRef,
    getVpnStatus: options => {state.readRequests.push(options); return state.read();},
    normalizeVpnTransport: value => value === 'vless' ? 'vless' : 'amneziawg',
    localStatusHealthReasons, staleHandshakeReconnectSeconds: 180,
    listenVpnStatusChanged: f => {receive = f; return () => {};},
  };
  const functions = ['nextVpnStatusWithState', 'areVpnStatusesEqual'].map(name => declaration(helpers, name))
    .concat(['vpnStatusCoreFromStatus', 'areVpnStatusCoresEqual'].map(name => declaration(connection, name))).join('\n');
  const callbacks = ['setVpnStatus', 'releaseVpnOperation', 'acquireVpnOperation', 'captureStatusReadOwner',
    'handleNativeWatchdogRecoveryStarted'].map(name => callback(name)).join('\n');
  const controls = new Function(...Object.keys(bindings), functions + '\n' + callbacks + '\n'
    + reconciliation + '\n' + listener + ';return {recoveryStarted: handleNativeWatchdogRecoveryStarted, acquire: acquireVpnOperation, release: releaseVpnOperation};')(
    ...Object.values(bindings));
  return {state, ref, operation, revision, generation, preferences, mounted, activeProfileRevisionRef,
    setActiveProfile, pendingProfileUpdates, profile, ...controls,
    receive: next => {state.native = next; receive(next);}, phase: () => phaseFor(state.core, false, false)};
}

test('a fresh verified AWG native event replaces watchdog degraded with connected', () => {
  const h = harness();
  h.recoveryStarted(); assert.equal(h.phase(), 'degraded');
  const fresh = {...h.state.native, latestHandshakeEpochMillis: Date.now(), rxBytes: 300};
  h.receive(fresh);
  assert.equal(h.ref.current.state, 'connected');
  assert.equal(h.phase(), 'connected');
  assert.equal(h.ref.current.verified, true);
  assert.equal(h.ref.current.latestHandshakeEpochMillis, fresh.latestHandshakeEpochMillis);
});

test('an event dropped during the lease converges through a fresh native read after release', async () => {
  const h = harness(); h.recoveryStarted(); const release = h.acquire();
  const fresh = {...h.state.native, latestHandshakeEpochMillis: Date.now(), rxBytes: 300};
  h.receive(fresh);
  assert.equal(h.state.native.state, 'connected');
  assert.equal(h.state.native.verified, true);
  assert.equal(h.phase(), 'degraded');
  release(); await flush();
  assert.deepEqual(h.state.readRequests, [{fresh: true}]);
  assert.equal(h.phase(), 'connected');
  assert.equal(h.ref.current.latestHandshakeEpochMillis, fresh.latestHandshakeEpochMillis);
});

test('delayed release reads yield to newer connect, stop, lease, session, preferences or unmount', async () => {
  for (const action of ['connect', 'stop', 'lease', 'completed-lease', 'session', 'preferences', 'unmount']) {
    const h = harness(); h.recoveryStarted(); let resolve;
    h.state.read = () => new Promise(r => {resolve = r;});
    h.acquire()();
    assert.equal(h.state.readRequests.length, 1);
    if (action === 'connect') h.generation.current++;
    if (action === 'stop') {const release = h.acquire(); h.ref.current = {...h.ref.current, state: 'disconnected'}; release();}
    if (action === 'lease') h.acquire();
    if (action === 'completed-lease') {h.state.read = () => new Promise(() => {}); h.acquire()();}
    if (action === 'session') h.state.sessionCurrent = false;
    if (action === 'preferences') h.preferences.current++;
    if (action === 'unmount') h.mounted.current = false;
    const before = h.ref.current;
    resolve({...h.state.native, rxBytes: 900}); await flush();
    assert.equal(h.ref.current, before, action);
  }
});

test('failed, unverified, stale, future, foreign and missing native proof never promote recovery', async () => {
  for (const patch of [null, {verified: false}, {latestHandshakeEpochMillis: undefined},
    {latestHandshakeEpochMillis: Date.now() - 181_000}, {latestHandshakeEpochMillis: Date.now() + 60_000},
    {transport: 'vless', verified: true, verificationEpochMillis: Date.now()}]) {
    const h = harness(); h.recoveryStarted();
    h.state.read = async () => {if (patch === null) throw new Error('isolated read failure'); return {...h.state.native, ...patch};};
    h.acquire()(); await flush();
    assert.equal(h.phase(), 'degraded');
  }
});

test('actual profile setter synchronously invalidates a pending read before React evaluates its updater', async () => {
  for (const change of ['version', 'device', 'functional-updater', 'clear']) {
    const h = harness(); h.recoveryStarted(); let resolve;
    h.state.read = () => new Promise(r => {resolve = r;});
    h.acquire()();
    assert.equal(h.state.readRequests.length, 1);
    const replacement = change === 'clear' ? null : {...h.profile,
      profileVersion: change === 'device' ? h.profile.profileVersion : h.profile.profileVersion + 1,
      device: change === 'device' ? {id: 'other-fixture-device'} : h.profile.device};
    h.setActiveProfile(change === 'functional-updater' ? () => replacement : replacement);
    assert.equal(h.activeProfileRevisionRef.current, 1, 'the authoritative fence changes synchronously');
    assert.equal(h.pendingProfileUpdates.length, 1);
    assert.equal(typeof h.pendingProfileUpdates[0], 'function', 'React updater has not executed or rendered');
    const before = h.ref.current;
    resolve({...h.state.native, rxBytes: 900}); await flush();
    assert.equal(h.ref.current, before, change);
    assert.equal(h.phase(), 'degraded', 'an older native proof cannot connect the replacement profile');
  }
});

test('unmounted releases perform no native read and an older owner cannot release a new lease', async () => {
  const h = harness(); h.recoveryStarted(); const oldRelease = h.acquire();
  const latestRelease = h.acquire(); oldRelease();
  assert.equal(h.operation.current, true); assert.equal(h.state.readRequests.length, 0);
  h.mounted.current = false; latestRelease(); await flush();
  assert.equal(h.state.readRequests.length, 0);
});

test('a fresh native leak-blocking result preserves blocking rather than displaying connected', async () => {
  const h = harness(); h.recoveryStarted();
  h.state.read = async () => ({...h.state.native, leakProtection: 'blocking'});
  h.acquire()(); await flush();
  assert.equal(h.phase(), 'blocked');
  assert.equal(h.ref.current.leakProtection, 'blocking');
});

test('the status path preserves native blocking and unverified evidence', () => {
  for (const patch of [{verified: false, latestHandshakeEpochMillis: 0, verificationReason: 'handshake_pending'},
    {leakProtection: 'blocking'}]) {
    const h = harness(); h.recoveryStarted(); h.receive({...h.state.native, ...patch});
    assert.notEqual(h.phase(), 'connected');
    for (const [key, value] of Object.entries(patch)) assert.equal(h.ref.current[key], value);
  }
});

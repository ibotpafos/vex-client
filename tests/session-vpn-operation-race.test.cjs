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
function callbacks(file, names) {
  const source = fs.readFileSync(path.join(repo, file), 'utf8');
  const root = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, file.endsWith('tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  const found = {};
  function visit(node) {
    if (ts.isVariableDeclaration(node) && names.includes(node.name.getText(root))) {
      assert.ok(ts.isCallExpression(node.initializer));
      found[node.name.getText(root)] = node.initializer.arguments[0].getText(root);
    }
    ts.forEachChild(node, visit);
  }
  visit(root);
  for (const name of names) assert.ok(found[name], `missing production callback ${name}`);
  return found;
}
function bind(callback, context) {
  const code = ts.transpileModule(`return (${callback});`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  return new Function(...Object.keys(context), code)(...Object.values(context));
}
const auth = callbacks('src/auth/session-context.tsx', ['sessionOperationIsCurrent', 'applySignOutState', 'signIn', 'refreshSession']);
const flow = callbacks('src/vpn/useVpnConnectionFlow.ts', ['requireCurrentSession', 'connectProfileWithEndpointFallback', 'connectCurrentVpn']);
const failure = callbacks('src/vpn/useVpnConnection.ts', ['handleVpnFailure', 'handlePowerPress']);
const { isCurrentSessionOperation } = policy('src/auth/sessionOperationGuard.ts');
const { isCurrentSessionMutation } = policy('src/auth/sessionMutationGuard.ts');
const { createSessionStore, createSessionMutationQueue, sessionKey, sessionHistoryKey } = policy('src/auth/sessionStoreCore.ts');
const { SessionOperationSupersededError } = policy('src/vpn/sessionOperation.ts');
const fallback = policy('src/vpn/connectionFallback.ts');
const { cleanupFailedVpnConnection } = policy('src/vpn/failedConnectionCleanup.ts', { './connectionFallback': fallback });
const { connectFreshSameLocationProfile } = policy('src/vpn/sameLocationProfileRecovery.ts');
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
function provider({ clear = async () => {}, disconnect = async () => {}, save = async () => {}, refresh } = {}) {
  let session = { accessToken: 'token-A', user: { id: 'A' } };
  let revision = 0;
  const shared = {
    sessionRef: { current: session }, sessionRevisionRef: { current: 0 }, sessionOperationsBlockedRef: { current: false },
    setSessionOperationRevision: value => { revision = value; }, clearSession: clear, disconnectVpn: disconnect,
    runSessionTransition: createSessionMutationQueue(), refreshInFlightRef: { current: null }, isCurrentSessionMutation,
    refreshApiSession: refresh ?? (async () => ({ ...session, accessToken: 'token-A-refreshed' })),
    clearClientData: () => {}, setSession: value => { session = value; }, setIsLoading: () => {},
    saveSession: save, setLoadError: () => {}, loadError: null, uploadClientDiagnostics: async () => {},
  };
  return {
    signOut: bind(auth.applySignOutState, shared), signIn: bind(auth.signIn, shared),
    refresh: bind(auth.refreshSession, shared), current: () => shared.sessionRef.current,
    guard: () => bind(auth.sessionOperationIsCurrent, { ...shared, sessionOperationRevision: revision, session, isCurrentSessionOperation }),
    rotateToken: () => { shared.sessionRef.current = { ...shared.sessionRef.current, accessToken: 'token-A-rotated' }; },
  };
}
const profile = {
  locationId: 'de', config: '[Interface]\nPrivateKey = fixture-A\nAddress = 10.0.0.2/32\nHeaderProtectionKey = fixture\n[Peer]\nEndpoint = fixture:443',
  device: { id: 'device-A', assignedIpv4: '10.0.0.2', endpoint: 'fixture:443' },
};
function connectionHarness(stage, platform = 'android') {
  const gate = deferred(), reached = deferred();
  const state = { nativeCalls: 0, cleanupCalls: 0, logoutCalls: 0, published: 0, cached: 0, resolutions: 0, nativeOwner: null };
  const wait = async (name, value) => {
    if (stage === name) { reached.resolve(); return await gate.promise; }
    return value;
  };
  const session = provider({ disconnect: async () => { state.logoutCalls++; state.nativeOwner = null; } });
  const mountedRef = { current: true };
  const requireCurrentSession = bind(flow.requireCurrentSession, {
    mountedRef, isCurrentSessionOperation: session.guard(), SessionOperationSupersededError,
  });
  const context = {
    Date, Error, requireCurrentSession, session: { accessToken: 'token-A', user: { id: 'A' } },
    Platform: { OS: platform }, antiLeakEnabled: true,
    prepareClientNetworkDiagnostics: () => wait('diagnostics'),
    withTimeout: operation => operation, vpnProfileAddressMatchesDevice: () => true,
    androidVpnProfileWithinBinderBudget: () => true,
    getVpnApplicationSelection: () => wait('applications', { mode: 'all', packageNames: [] }),
    dynamicRouteRuntime: { prepare: () => wait('route'), attempts: () => [{ profile }], clearActive: () => {}, recordSuccess: () => {}, recordFailure: () => {} },
    ...fallback, routeTransport: () => 'awg3_direct',
    getVpnStatus: () => wait('status', { state: 'disconnected' }),
    connectVpn: async () => {
      state.nativeCalls++; state.nativeOwner = 'A';
      if (stage === 'fresh-profile') throw new Error('VPN handshake failed');
      return wait('native', { state: 'connected' });
    },
    connectAttemptTimeoutMs: 100, waitForVerifiedVpnConnection: () => wait('verification', { state: 'connected' }),
    selectedLocationId: stage === 'persist' ? 'previous' : 'de', serverSelectionMode: 'auto', availableLocations: [{ id: 'de' }],
    chooseBestVpnLocation: () => ({ id: 'de' }), profileResolutionOrder: id => [{ id }], explicitConnectProfileResolutionOptions: {},
    resolveConnectableVpnProfile: async () => {
      state.resolutions++;
      return wait(state.resolutions > 1 ? 'fresh-profile' : 'profile', profile);
    },
    isProfileResolutionFallbackError: () => false, resolveProfileOrSkipMissing: resolve => resolve(), connectFreshSameLocationProfile,
    cleanupFailedVpnConnection, disconnectVpn: async () => { state.cleanupCalls++; state.nativeOwner = null; },
    setSelectedVpnLocation: location => wait('persist', location), setSelectedLocationId: () => {},
    cacheProfile: () => { state.cached++; }, setActiveProfile: () => { state.published++; }, setVpnStatus: () => {},
    saveHotVpnProfile: async () => {}, uploadClientDiagnostics: async () => {}, submitClientDiagnostics: async () => {},
    reportVpnConnectEvent: () => {}, vpnConnectTelemetry: () => ({}), vpnConnectTimingSamples: () => ({}),
    vpnStatus: { state: 'disconnected' }, clientLatencyMs: null, errorMessage: error => error.message,
    withLastSuccessfulEndpoint: value => value,
  };
  context.connectProfileWithEndpointFallback = bind(flow.connectProfileWithEndpointFallback, context);
  return { state, session, gate, reached, mountedRef, connect: bind(flow.connectCurrentVpn, context) };
}

test('logout invalidates old callbacks synchronously before storage or native teardown', async () => {
  const storage = deferred(); let nativeCalls = 0;
  const session = provider({ clear: () => storage.promise, disconnect: async () => { nativeCalls++; } });
  const oldGuard = session.guard(); assert.equal(oldGuard(), true);
  const logout = session.signOut();
  assert.equal(oldGuard(), false);
  assert.equal(session.guard()(), false, 'new operations are blocked during logout');
  assert.equal(nativeCalls, 0, 'storage is still pending');
  storage.resolve(); await logout;
  assert.equal(nativeCalls, 1); assert.equal(session.guard()(), false);
});

test('failed native logout retains the account and invalidates the old operation', async () => {
  const session = provider({ disconnect: async () => { throw new Error('native teardown failed'); } });
  const oldGuard = session.guard();
  await assert.rejects(session.signOut(), /native teardown failed/);
  assert.equal(oldGuard(), false); assert.equal(session.guard()(), true, 'the mounted account can retry');
});

test('same-account token refresh preserves an operation; a new login never revives it', async () => {
  const session = provider(); const oldGuard = session.guard();
  session.rotateToken(); assert.equal(oldGuard(), true);
  await session.signOut(); await session.signIn({ accessToken: 'new-token-A', user: { id: 'A' } });
  assert.equal(oldGuard(), false); assert.equal(session.guard()(), true);
});

for (const stage of ['profile', 'diagnostics', 'applications', 'route', 'status', 'native', 'verification', 'fresh-profile', 'persist']) {
  test(`logout during ${stage} prevents old-account reconnect, publication and late cleanup`, async () => {
    const h = connectionHarness(stage);
    const pending = h.connect(); const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    await h.reached.promise;
    await h.session.signOut(); await h.session.signIn({ accessToken: 'token-B', user: { id: 'B' } });
    h.state.nativeOwner = 'B';
    const callsBeforeCompletion = h.state.nativeCalls;
    h.gate.resolve(stage === 'profile' || stage === 'fresh-profile' ? profile : stage === 'persist' ? 'de' : { state: 'connected', mode: 'all', packageNames: [] });
    await rejected;
    assert.equal(h.state.nativeCalls, callsBeforeCompletion, 'old operation cannot start another native attempt');
    assert.equal(h.state.cleanupCalls, 0, 'old cleanup must not disconnect B');
    assert.equal(h.state.nativeOwner, 'B'); assert.equal(h.state.published, 0); assert.equal(h.state.cached, 0);
    assert.equal(h.state.logoutCalls, 1);
  });
}

for (const stage of ['profile', 'native']) {
  test(`late ${stage} failure after logout is cancellation and cannot trigger recovery`, async () => {
    const h = connectionHarness(stage);
    const pending = h.connect(); const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    await h.reached.promise; await h.session.signOut();
    h.gate.reject(Object.assign(new Error(stage === 'native' ? 'VPN handshake failed' : 'authentication required'), { status: 401 }));
    await rejected; assert.equal(h.state.cleanupCalls, 0); assert.equal(h.state.resolutions, 1);
  });
}

test('unmount cancels preparation even while the parent auth session remains active', async () => {
  const h = connectionHarness('applications', 'ios');
  const pending = h.connect(); const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  await h.reached.promise; h.mountedRef.current = false;
  h.gate.resolve({ mode: 'all', packageNames: [] }); await rejected;
  assert.equal(h.state.nativeCalls, 0); assert.equal(h.state.cleanupCalls, 0);
});

test('token refresh during profile resolution still completes the same-account tunnel', async () => {
  const h = connectionHarness('profile'); const pending = h.connect();
  await h.reached.promise; h.session.rotateToken(); h.gate.resolve(profile); await pending;
  assert.equal(h.state.nativeCalls, 1); assert.equal(h.state.published, 1); assert.equal(h.state.cleanupCalls, 0);
});

function failureHarness(session) {
  const refresh = deferred(), status = deferred();
  const calls = { signOut: 0, errors: [], statuses: [], diagnostics: 0, refresh: 0 };
  const handleFailure = bind(failure.handleVpnFailure, {
    isCurrentSessionOperation: session.guard(), SessionOperationSupersededError,
    errorMessage: error => error.message, playErrorHaptic: () => {},
    setVpnStatus: value => { calls.statuses.push(value); }, setVpnError: value => { calls.errors.push(value); },
    nextVpnStatusWithState: (current, state) => ({ ...current, state }), getVpnStatus: () => status.promise,
    isAuthenticationError: message => message.includes('401'),
    refreshSession: () => { calls.refresh++; return refresh.promise; },
    submitClientDiagnosticsEvent: async () => { calls.diagnostics++; }, signOut: async () => { calls.signOut++; },
  });
  return { calls, handleFailure, refresh, status };
}
const flush = () => new Promise(resolve => setImmediate(resolve));

for (const completion of ['reject', 'resolve']) {
  test(`old failure handler cannot publish or log out B after late refresh ${completion}`, async () => {
    const session = provider(), h = failureHarness(session);
    h.handleFailure(new Error('401 expired token'), 'disconnected');
    assert.equal(h.calls.refresh, 1);
    await session.signOut(); await session.signIn({ accessToken: 'token-B', user: { id: 'B' } });
    const errorsBeforeCompletion = h.calls.errors.length, statusesBeforeCompletion = h.calls.statuses.length;
    h.status.resolve({ state: 'connected' });
    if (completion === 'reject') h.refresh.reject(new Error('401 expired refresh'));
    else h.refresh.resolve({ accessToken: 'token-A-refreshed', user: { id: 'A' } });
    await flush(); await flush();
    assert.equal(h.calls.signOut, 0); assert.equal(h.calls.diagnostics, 0);
    assert.equal(h.calls.errors.length, errorsBeforeCompletion); assert.equal(h.calls.statuses.length, statusesBeforeCompletion);
  });
}

test('the current session still reports a definitively rejected refresh and signs out', async () => {
  const h = failureHarness(provider()); h.handleFailure(new Error('401 expired token'), 'disconnected');
  h.status.resolve({ state: 'disconnected' }); h.refresh.reject(new Error('401 expired refresh'));
  await flush(); await flush();
  assert.equal(h.calls.signOut, 1); assert.equal(h.calls.diagnostics, 1);
  assert.ok(h.calls.errors.some(value => value.includes('Сессия истекла')));
});

test('a retained failure callback does nothing after its login ends', async () => {
  const session = provider(), h = failureHarness(session); await session.signOut();
  h.handleFailure(new Error('401 expired token'), 'disconnected');
  assert.equal(h.calls.refresh, 0); assert.equal(h.calls.errors.length, 0); assert.equal(h.calls.statuses.length, 0);
});

function storageFixture(blockKey, blockToken) {
  const gate = deferred(), reached = deferred(), data = new Map();
  let blockedOnce = false;
  const store = createSessionStore({
    getItemAsync: async key => data.get(key) ?? null,
    setItemAsync: async (key, value) => {
      if (!blockedOnce && key === blockKey && JSON.parse(value).accessToken === blockToken) {
        blockedOnce = true; reached.resolve(); await gate.promise;
      }
      data.set(key, value);
    },
    deleteItemAsync: async key => { data.delete(key); }, clearSensitiveStorageHistory: async () => { data.clear(); },
  });
  return { gate, reached, data, store };
}
const account = (id, accessToken) => ({ accessToken, user: { id, email: `${id}@fixture.invalid` } });

for (const key of [sessionKey, sessionHistoryKey]) {
  for (const mutation of ['refresh', 'signIn']) {
    test(`logout and B login win over delayed A ${mutation} ${key} persistence`, async () => {
      const f = storageFixture(key, 'delayed-A');
      await f.store.save(account('A', 'token-A'));
      const session = provider({ save: f.store.save, clear: f.store.clear, refresh: async () => account('A', 'delayed-A') });
      const oldMutation = mutation === 'refresh' ? session.refresh() : session.signIn(account('A', 'delayed-A'));
      await f.reached.promise;
      const logout = session.signOut(), login = session.signIn(account('B', 'token-B'));
      f.gate.resolve(); await Promise.all([oldMutation, logout, login]);
      assert.equal(session.current().user.id, 'B');
      assert.equal(JSON.parse(f.data.get(sessionKey)).user.id, 'B');
      assert.equal(JSON.parse(f.data.get(sessionHistoryKey)).user.id, 'B');
      assert.equal((await f.store.load()).user.id, 'B');
    });
  }
}

test('B login waits for old logout native teardown and old completion cannot clear B', async () => {
  const native = deferred(), reached = deferred(); let saved = 0;
  const session = provider({ save: async () => { saved++; }, disconnect: async () => { reached.resolve(); await native.promise; } });
  const logout = session.signOut(); await reached.promise;
  const login = session.signIn(account('B', 'token-B')); await flush();
  assert.equal(saved, 0, 'B cannot be exposed while old teardown is pending');
  native.resolve(); await Promise.all([logout, login]); assert.equal(session.current().user.id, 'B');
});

test('B refresh never joins an in-flight refresh from A after logout and login', async () => {
  const a = deferred(), b = deferred(), requests = [];
  const session = provider({ refresh: token => { requests.push(token); return token === 'token-A' ? a.promise : b.promise; } });
  const old = session.refresh(), oldRejected = assert.rejects(old, /401 old A/);
  await session.signOut(); await session.signIn(account('B', 'token-B'));
  const current = session.refresh(), coalesced = session.refresh();
  assert.deepEqual(requests, ['token-A', 'token-B'], 'unchanged B session still coalesces its own refresh');
  a.reject(new Error('401 old A')); await oldRejected;
  const afterOldFailure = session.refresh();
  assert.equal(requests.length, 2, 'old A finally must not clear the pending B refresh');
  b.resolve(account('B', 'token-B-refreshed'));
  assert.equal((await current).user.id, 'B'); assert.equal((await coalesced).accessToken, 'token-B-refreshed');
  assert.equal((await afterOldFailure).user.id, 'B');
  assert.equal(session.current().accessToken, 'token-B-refreshed');
});

test('a rejected primary storage write does not prevent queued logout and next login', async () => {
  const data = new Map();
  const store = createSessionStore({
    getItemAsync: async key => data.get(key) ?? null,
    setItemAsync: async (key, value) => { if (JSON.parse(value).accessToken === 'fail') throw new Error('storage failure'); data.set(key, value); },
    deleteItemAsync: async key => { data.delete(key); }, clearSensitiveStorageHistory: async () => { data.clear(); },
  });
  const failed = assert.rejects(store.save(account('A', 'fail')), /storage failure/);
  const clear = store.clear(), save = store.save(account('B', 'token-B'));
  await Promise.all([failed, clear, save]); assert.equal((await store.load()).user.id, 'B');
});

for (const stage of ['connect', 'cancel-status']) {
  test(`old power operation after ${stage} cannot disconnect or release B's operation lease`, async () => {
    const session = provider(), gate = deferred(), reached = deferred();
    const operation = { current: stage === 'cancel-status' }, generation = { current: 0 };
    let busy = false, disconnects = 0;
    const wait = () => { reached.resolve(); return gate.promise; };
    const power = bind(failure.handlePowerPress, {
      isCurrentSessionOperation: session.guard(), autoConnectAttemptedRef: { current: false },
      isVpnBusy: stage === 'cancel-status', vpnOperationInFlightRef: operation, vpnConnectGenerationRef: generation,
      connectionPhase: 'connecting', isConnected: false, isLeakBlocked: false, isKeyRotationBusy: false,
      setIsVpnBusy: value => { busy = value; }, setVpnError: () => {}, setVpnStatus: () => {},
      getVpnStatus: wait, connectCurrentVpn: wait, disconnectVpn: async () => { disconnects++; return { state: 'disconnected' }; },
      disconnectedVpnStatus: () => ({ state: 'disconnected' }), dynamicRouteRuntime: { clearActive: () => {} },
      session: account('A', 'token-A'), activeProfile: profile, reportVpnDisconnectEvent: () => {},
      nextVpnStatusWithState: (current, state) => ({ ...current, state }), handleVpnFailure: () => {},
      playWarningHaptic: () => {}, playMediumImpactHaptic: () => {}, playSuccessHaptic: () => {},
    });
    const pending = power(); await reached.promise;
    await session.signOut(); await session.signIn(account('B', 'token-B'));
    operation.current = true; generation.current++; busy = true;
    gate.resolve({ state: 'connected' }); await pending;
    assert.equal(disconnects, 0); assert.equal(operation.current, true); assert.equal(busy, true);
  });
}

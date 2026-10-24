const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');

const repo = path.resolve(__dirname, '..');
function policy(file, dependencies = {}, globals = {}) {
  const code = ts.transpileModule(fs.readFileSync(path.join(repo, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { ...globals, exports, Error, require: name => {
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
const { ApiRequestError } = policy('src/api/error.ts');
const { createSessionRestoreRefresh } = policy('src/auth/sessionRestoreRefresh.ts');
const fallback = policy('src/vpn/connectionFallback.ts');
const { cleanupFailedVpnConnection } = policy('src/vpn/failedConnectionCleanup.ts', { './connectionFallback': fallback });
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
function provider({ clear = async () => {}, disconnect = async () => {}, save = async () => {}, refresh, restoreRefresh = createSessionRestoreRefresh() } = {}) {
  let session = { accessToken: 'token-A', user: { id: 'A' } };
  let revision = 0;
  const shared = {
    sessionRef: { current: session }, sessionRevisionRef: { current: 0 }, sessionOperationsBlockedRef: { current: false },
    setSessionOperationRevision: value => { revision = value; }, clearSession: clear, disconnectVpn: disconnect,
    runSessionTransition: createSessionMutationQueue(), refreshInFlightRef: { current: null }, isCurrentSessionMutation,
    restoreRefresh,
    refreshApiSession: refresh ?? (async () => ({ ...session, accessToken: 'token-A-refreshed' })),
    clearClientData: () => {}, setSession: value => { session = value; }, setIsLoading: () => {},
    saveSession: save, setLoadError: () => {}, loadError: null, uploadClientDiagnostics: async () => {},
  };
  return {
    restoreRefresh: shared.restoreRefresh,
    signOut: bind(auth.applySignOutState, shared), signIn: bind(auth.signIn, shared),
    refresh: bind(auth.refreshSession, shared), current: () => shared.sessionRef.current, published: () => session,
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
  const isCurrentSessionOperation = session.guard();
  const requireCurrentSession = bind(flow.requireCurrentSession, {
    mountedRef, isCurrentSessionOperation, SessionOperationSupersededError,
  });
  const context = {
    Date, Error, requireCurrentSession, isCurrentSessionOperation, SessionOperationSupersededError, session: { accessToken: 'token-A', user: { id: 'A' } },
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
    isProfileResolutionFallbackError: () => false, resolveProfileOrSkipMissing: resolve => resolve(),
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

for (const cancel of [false, true]) {
  test(`a policy arriving during the first native attempt preserves relay recovery; cancel=${cancel}`, async () => {
    let current = true;
    let prepared = false;
    const nativeConfigs = [];
    const reports = [];
    const relayProfile = fallback.profileWithEndpoint(profile, 'relay.fixture:443');
    assert.ok(relayProfile);
    const direct = { id: 'direct', pathKind: 'direct' };
    const relay = { id: 'relay', pathKind: 'relay' };
    const context = {
      Date, Error, SessionOperationSupersededError,
      requireCurrentSession: () => { if (!current) throw new SessionOperationSupersededError(); },
      isCurrentSessionOperation: () => current, session: { accessToken: 'token-A', user: { id: 'A' } },
      Platform: { OS: 'android' }, antiLeakEnabled: true,
      prepareClientNetworkDiagnostics: async () => {}, withTimeout: operation => operation,
      vpnProfileAddressMatchesDevice: () => true, androidVpnProfileWithinBinderBudget: () => true,
      getVpnApplicationSelection: async () => ({ mode: 'all', packageNames: [] }),
      dynamicRouteRuntime: {
        prepare: async () => {},
        attempts: () => prepared ? [{ profile, candidate: direct }, { profile: relayProfile, candidate: relay }] : [{ profile }],
        clearActive: () => {}, recordSuccess: () => {}, recordFailure: () => {},
      },
      ...fallback, routeTransport: candidate => candidate.pathKind === 'relay' ? 'awg3_relay' : 'awg3_direct',
      getVpnStatus: async () => ({ state: 'disconnected' }),
      connectVpn: async config => {
        nativeConfigs.push(config);
        if (nativeConfigs.length === 1) {
          prepared = true;
          if (cancel) current = false;
          throw new Error('VPN handshake timed out');
        }
        return { state: 'connected' };
      },
      connectAttemptTimeoutMs: 100,
      waitForVerifiedVpnConnection: async value => value,
      submitClientDiagnostics: async (_token, report) => { reports.push(report); }, withLastSuccessfulEndpoint: value => value,
    };
    const pending = bind(flow.connectProfileWithEndpointFallback, context)(profile);
    if (cancel) {
      await assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
      assert.equal(nativeConfigs.length, 1);
    } else {
      const result = await pending;
      assert.equal(nativeConfigs.length, 2, 'Use the newly prepared relay without retrying the failed direct endpoint');
      assert.equal(nativeConfigs[1], relayProfile.config);
      assert.equal(result.profile, relayProfile);
      assert.equal(reports[0].connectionEvent, 'fallback_succeeded');
      assert.equal(reports[0].transportFrom, undefined, 'The original profile transport has no policy attribution');
    }
  });
}

for (const stage of ['profile', 'diagnostics', 'applications', 'route', 'status', 'native', 'verification', 'fresh-profile', 'persist']) {
  test(`explicit cancellation during ${stage} fences late native work and publication in the same login`, async () => {
    const h = connectionHarness(stage);
    let current = true;
    const pending = h.connect({ isCurrentOperation: () => current });
    const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    await h.reached.promise;
    current = false;
    h.state.nativeOwner = 'newer-intent';
    const calls = h.state.nativeCalls;
    h.gate.resolve(stage === 'profile' || stage === 'fresh-profile' ? profile : stage === 'persist' ? 'de' : { state: 'connected', mode: 'all', packageNames: [] });
    await rejected;
    assert.equal(h.state.nativeCalls, calls, 'a canceled request must not start another native connection');
    assert.equal(h.state.cleanupCalls, 0, 'late cleanup must not stop the newer intent');
    assert.equal(h.state.nativeOwner, 'newer-intent');
    assert.equal(h.state.published, 0);
    assert.equal(h.state.cached, 0);
  });
}

for (const outcome of ['resolve', 'reject']) {
  test(`a canceled power operation ${outcome} cannot stop or unlock a newer connection`, async () => {
    const old = deferred(), newer = deferred(), started = [];
    let disconnects = 0, failures = 0;
    const context = {
      isCurrentSessionOperation: () => true, autoConnectAttemptedRef: { current: false },
      isVpnBusy: false, vpnOperationInFlightRef: { current: false }, vpnConnectGenerationRef: { current: 0 },
      connectionPhase: 'idle', isConnected: false, isLeakBlocked: false, isKeyRotationBusy: false,
      setIsVpnBusy: value => { context.isVpnBusy = value; }, setVpnError: () => {}, setVpnStatus: () => {},
      getVpnStatus: async () => ({ state: 'disconnected' }),
      connectCurrentVpn: options => { started.push(options); return started.length === 1 ? old.promise : newer.promise; },
      disconnectVpn: async () => { disconnects++; return { state: 'disconnected' }; },
      disconnectedVpnStatus: () => ({ state: 'disconnected' }), dynamicRouteRuntime: { clearActive: () => {} },
      session: account('A', 'token-A'), activeProfile: null, reportVpnDisconnectEvent: () => {},
      nextVpnStatusWithState: (current, state) => ({ ...current, state }), handleVpnFailure: () => { failures++; },
      playWarningHaptic: () => {}, playMediumImpactHaptic: () => {}, playSuccessHaptic: () => {},
    };
    const original = bind(failure.handlePowerPress, context)();
    context.connectionPhase = 'connecting';
    await bind(failure.handlePowerPress, context)();
    context.connectionPhase = 'idle';
    const replacement = bind(failure.handlePowerPress, context)();
    if (outcome === 'resolve') old.resolve(); else old.reject(new Error('late old native failure'));
    await original;
    assert.equal(disconnects, 1, 'only the explicit cancellation owns teardown');
    assert.equal(failures, 0, 'the canceled result cannot overwrite a new connection with an error');
    assert.equal(context.vpnOperationInFlightRef.current, true);
    assert.equal(context.isVpnBusy, true);
    assert.equal(started[0].isCurrentOperation(), false);
    assert.equal(started[1].isCurrentOperation(), true);
    newer.resolve();
    await replacement;
    assert.equal(context.vpnOperationInFlightRef.current, false);
  });
}

for (const busy of [false, true]) test(`verification remains explicitly cancellable with local busy=${busy}`, async () => {
  let disconnects = 0;
  const context = {
    isCurrentSessionOperation: () => true, autoConnectAttemptedRef: { current: false },
    isVpnBusy: busy, vpnOperationInFlightRef: { current: busy }, vpnConnectGenerationRef: { current: 1 },
    connectionPhase: 'verifying', isConnected: false, isLeakBlocked: false,
    setIsVpnBusy: () => {}, setVpnError: () => {}, setVpnStatus: () => {},
    getVpnStatus: async () => ({ state: 'connected', verified: false }),
    disconnectVpn: async () => { disconnects++; return { state: 'disconnected' }; },
    disconnectedVpnStatus: () => ({ state: 'disconnected' }), dynamicRouteRuntime: { clearActive: () => {} },
    session: null, activeProfile: null, nextVpnStatusWithState: (current, state) => ({ ...current, state }),
    handleVpnFailure: error => { throw error; }, playWarningHaptic: () => {}, playSuccessHaptic: () => {},
  };
  await bind(failure.handlePowerPress, context)();
  assert.equal(disconnects, 1);
});

test('a failed native cancellation is reported instead of silently fabricating a stopped tunnel', async () => {
  let failures = 0, successes = 0;
  const context = {
    isCurrentSessionOperation: () => true, autoConnectAttemptedRef: { current: false },
    isVpnBusy: true, vpnOperationInFlightRef: { current: true }, vpnConnectGenerationRef: { current: 1 },
    connectionPhase: 'connecting', isConnected: false, isLeakBlocked: false,
    setIsVpnBusy: () => {}, setVpnError: () => {}, setVpnStatus: () => {},
    getVpnStatus: async () => ({ state: 'connected', verified: false }),
    disconnectVpn: async () => { throw new Error('native stop failed'); },
    disconnectedVpnStatus: () => ({ state: 'disconnected' }), dynamicRouteRuntime: { clearActive: () => {} },
    session: null, activeProfile: null, nextVpnStatusWithState: (current, state) => ({ ...current, state }),
    handleVpnFailure: () => { failures++; }, playWarningHaptic: () => {}, playSuccessHaptic: () => { successes++; },
  };
  await bind(failure.handlePowerPress, context)();
  assert.equal(failures, 1);
  assert.equal(successes, 0);
});

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

function restoreHarness({ load, refresh, clear = async () => {}, save = async () => {}, restoreRefresh = createSessionRestoreRefresh() }) {
  const source = fs.readFileSync(process.env.VEX_SESSION_RESTORE_SOURCE ?? path.join(repo, 'src/auth/session-context.tsx'), 'utf8');
  const root = ts.createSourceFile('session-context.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  let callback;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && node.name.getText(root) === 'restoreSession') {
      callback = node.initializer.getText(root);
    }
    ts.forEachChild(node, visit);
  }
  visit(root);
  assert.ok(callback, 'missing production startup restoration callback');
  const state = { session: undefined, loading: true, error: null };
  const context = {
    mounted: true, restoreRevision: 0, sessionRevisionRef: { current: 0 }, sessionRef: { current: null },
    loadSessionWithRetry: operation => operation(), loadSession: load, refreshApiSession: refresh,
    restoreRefresh,
    runSessionTransition: createSessionMutationQueue(), saveSession: save, clearSession: clear,
    ApiRequestError, errorMessage: (error, fallback) => error instanceof Error ? error.message : fallback,
    setSession: value => { state.session = value; }, setIsLoading: value => { state.loading = value; },
    setLoadError: value => { state.error = value; },
  };
  const code = ts.transpileModule(`return { restore: (${callback}), unmount: () => { mounted = false; } };`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return { ...new Function(...Object.keys(context), code)(...Object.values(context)), state, context };
}

test('rejected startup token releases loading even when secure-storage deletion fails', async () => {
  const h = restoreHarness({
    load: async () => ({ accessToken: 'rejected-A', user: { id: 'A' } }),
    refresh: async () => { throw new ApiRequestError('session revoked', { status: 401 }); },
    clear: async () => { throw new Error('keychain temporarily unavailable'); },
  });
  await h.restore();
  assert.equal(h.state.loading, false, 'startup must not hang on a cleanup failure');
  assert.equal(h.state.session, null, 'a rejected token is never exposed as an offline session');
  assert.match(h.state.error, /keychain temporarily unavailable/);
});

test('unmounted restoration does not rotate or persist a late loaded token', async () => {
  const load = deferred(); let refreshes = 0, saves = 0;
  const h = restoreHarness({ load: () => load.promise,
    refresh: async session => { refreshes++; return session; }, save: async () => { saves++; },
  });
  const pending = h.restore(); h.unmount();
  load.resolve({ accessToken: 'old-A', user: { id: 'A' } }); await pending;
  assert.equal(refreshes, 0, 'discarded startup must not revoke the token of a new mount');
  assert.equal(saves, 0); assert.equal(h.state.session, undefined);
});

test('late rejected refresh from an unmounted provider cannot clear the next mount storage', async () => {
  const refresh = deferred(); let clears = 0;
  const h = restoreHarness({ load: async () => ({ accessToken: 'old-A', user: { id: 'A' } }),
    refresh: () => refresh.promise, clear: async () => { clears++; },
  });
  const pending = h.restore(); await flush(); h.unmount();
  refresh.reject(new ApiRequestError('old token rejected', { status: 401 })); await pending;
  assert.equal(clears, 0, 'cleanup belongs only to the still-mounted login attempt');
  assert.equal(h.state.session, undefined);
});

for (const completeBeforeRemount of [false, true]) {
  test(`startup rotation survives remount with response ${completeBeforeRemount ? 'already complete' : 'pending'}`, async () => {
    const response = deferred(), restoreRefresh = createSessionRestoreRefresh();
    let stored = { accessToken: 'old-A', user: { id: 'A' } }, refreshes = 0, saves = 0, clears = 0;
    const rotated = { ...stored, accessToken: 'rotated-A' };
    const dependencies = {
      restoreRefresh, load: async () => stored,
      refresh: () => {
        if (++refreshes > 1) return Promise.reject(new ApiRequestError('old token revoked by rotation', { status: 401 }));
        return response.promise;
      },
      save: async value => { stored = value; saves++; },
      clear: async () => { stored = null; clears++; },
    };
    const oldMount = restoreHarness(dependencies), oldRestore = oldMount.restore();
    await flush(); oldMount.unmount();
    if (completeBeforeRemount) { response.resolve(rotated); await oldRestore; }
    const newMount = restoreHarness(dependencies), newRestore = newMount.restore();
    await flush(); response.resolve(rotated);
    await Promise.all([oldRestore, newRestore]);
    assert.equal(refreshes, 1, 'both mounts share the one rotating refresh');
    assert.equal(saves, 1, 'only the current mount persists the rotation');
    assert.equal(clears, 0);
    assert.equal(stored.accessToken, 'rotated-A');
    assert.equal(newMount.state.session.accessToken, 'rotated-A');
    assert.equal(newMount.state.loading, false);
    assert.equal(oldMount.state.session, undefined);
  });
}

test('a startup refresh failure can be retried and cannot clear a newer token flight', async () => {
  const handoff = createSessionRestoreRefresh(), old = deferred(); let retries = 0;
  const rejected = assert.rejects(handoff.run('A', () => old.promise), /offline/);
  const current = handoff.run('B', async () => ({ accessToken: 'rotated-B' }));
  old.reject(new Error('offline')); await rejected;
  assert.equal(await handoff.run('B', () => { throw new Error('unexpected duplicate refresh'); }), await current);
  await assert.rejects(handoff.run('A', async () => { retries++; throw new Error('offline'); }), /offline/);
  await handoff.run('A', async () => { retries++; return { accessToken: 'rotated-A' }; });
  assert.equal(retries, 2);
});

for (const mutation of ['signIn', 'signOut']) {
  test(`${mutation} invalidates the retained startup refresh handoff`, async () => {
    const p = provider(), handoff = p.restoreRefresh;
    await handoff.run('old-A', async () => ({ accessToken: 'rotated-A' }));
    if (mutation === 'signIn') await p.signIn({ accessToken: 'B', user: { id: 'B' } });
    else await p.signOut();
    let calls = 0;
    await handoff.run('old-A', async () => { calls++; return { accessToken: 'new-A' }; });
    assert.equal(calls, 1);
  });
}

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

function nativeStorageFixture(blockKey) {
  const data = new Map(), deletions = [];
  let blocked = false;
  const nativeStorage = policy('src/native/secureStore.ts', {
    'react-native': { Platform: { OS: 'android' } },
    './secureStoreCore': policy('src/native/secureStoreCore.ts'),
    'expo-secure-store': {
      getItemAsync: async key => data.get(key) ?? null,
      setItemAsync: async (key, value) => { data.set(key, value); },
      deleteItemAsync: async key => {
        deletions.push(key);
        if (blocked && key === blockKey) throw new Error('temporary keychain deletion failure');
        data.delete(key);
      },
    },
  });
  return { data, deletions, store: createSessionStore(nativeStorage), block: () => { blocked = true; }, unblock: () => { blocked = false; } };
}

for (const key of [sessionKey, sessionHistoryKey]) {
  test(`failed native deletion of ${key} keeps logout retryable until credentials are removed`, async () => {
    const f = nativeStorageFixture(key); let nativeStops = 0;
    await f.store.save(account('A', 'token-A'));
    const preserved = ['vex.app.install_id.v1', 'vex.auth.device_identity.v1', 'vex.vpn.legacy_key_owner.v1', 'vex.vpn.account_registration.v1.41', 'vex.vpn.account_keys.v1.fixture-A'];
    for (const name of preserved) f.data.set(name, `fixture:${name}`);
    const p = provider({ clear: f.store.clear, save: f.store.save, disconnect: async () => { nativeStops++; } });
    const oldGuard = p.guard(); f.block();
    await assert.rejects(p.signOut(), /temporary keychain deletion failure/);
    assert.equal(nativeStops, 1, 'failed durable cleanup must still retire the native tunnel');
    assert.equal(p.current().user.id, 'A'); assert.equal(p.published().user.id, 'A', 'Settings stays mounted to offer logout retry');
    assert.equal(oldGuard(), false); assert.equal(p.guard()(), true);
    for (const name of [sessionKey, sessionHistoryKey, 'vex.vpn.hot_profiles.v1']) assert.ok(f.deletions.includes(name), `all cleanup keys attempted: ${name}`);
    f.unblock(); await p.signOut();
    assert.equal(nativeStops, 2); assert.equal(p.current(), null); assert.equal(p.published(), null);
    assert.equal(await f.store.load(), null, 'successful logout cannot restore either credential copy');
    for (const name of preserved) assert.equal(f.data.get(name), `fixture:${name}`);
  });

  test(`B login wins after A logout fails deleting ${key}`, async () => {
    const f = nativeStorageFixture(key);
    await f.store.save(account('A', 'token-A'));
    const p = provider({ clear: f.store.clear, save: f.store.save });
    const oldGuard = p.guard(); f.block();
    const rejectedLogout = assert.rejects(p.signOut(), /temporary keychain deletion failure/);
    const login = p.signIn(account('B', 'token-B'));
    await Promise.all([rejectedLogout, login]);
    assert.equal(oldGuard(), false); assert.equal(p.current().user.id, 'B'); assert.equal(p.published().user.id, 'B');
    assert.equal((await f.store.load()).user.id, 'B');
    for (const name of [sessionKey, sessionHistoryKey]) assert.equal(JSON.parse(f.data.get(name)).user.id, 'B');
  });
}

test('ancillary native cache deletion failure does not hide successful credential removal', async () => {
  const f = nativeStorageFixture('vex.vpn.hot_profiles.v1');
  await f.store.save(account('A', 'token-A')); f.data.set('vex.vpn.hot_profiles.v1', 'fixture'); f.block();
  const p = provider({ clear: f.store.clear });
  await p.signOut(); assert.equal(p.current(), null); assert.equal(await f.store.load(), null);
});

function legacyWebStorageFixture(blockKey) {
  const data = new Map(), deletions = [];
  let blocked = false;
  const localStorage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => { data.set(key, value); },
    removeItem: key => {
      deletions.push(key);
      if (blocked && key === blockKey) throw new Error('legacy web auth removal blocked');
      data.delete(key);
    },
  };
  const freshAdapter = () => policy('src/native/secureStore.ts', {
    'react-native': { Platform: { OS: 'web' } },
    './secureStoreCore': policy('src/native/secureStoreCore.ts'),
    'expo-secure-store': {},
  }, { localStorage });
  const adapter = freshAdapter();
  return {
    data, deletions, adapter, store: createSessionStore(adapter),
    reload: () => createSessionStore(freshAdapter()).load(),
    block: () => { blocked = true; }, unblock: () => { blocked = false; },
    seedAccount: () => { for (const key of [sessionKey, sessionHistoryKey]) data.set(key, JSON.stringify(account('A', 'token-A'))); },
  };
}

for (const key of [sessionKey, sessionHistoryKey]) {
  test(`blocked legacy web ${key} deletion rejects logout until retry prevents reload resurrection`, async () => {
    const f = legacyWebStorageFixture(key); f.seedAccount(); f.block(); let nativeStops = 0;
    assert.equal((await f.store.load()).user.id, 'A', 'legacy reads and migration remain available');
    const p = provider({ clear: f.store.clear, save: f.store.save, disconnect: async () => { nativeStops++; } });
    const oldGuard = p.guard();
    await assert.rejects(p.signOut(), /legacy web auth removal blocked/);
    assert.equal(nativeStops, 1); assert.equal(p.current().user.id, 'A'); assert.equal(p.published().user.id, 'A');
    assert.equal(oldGuard(), false);
    for (const name of [sessionKey, sessionHistoryKey, 'vex.vpn.hot_profiles.v1']) assert.ok(f.deletions.includes(name));
    f.unblock(); await p.signOut();
    assert.equal(p.current(), null); assert.equal(p.published(), null); assert.equal(nativeStops, 2);
    assert.equal(await f.reload(), null, 'a fresh web module must not adopt the logged-out legacy account');
  });

  test(`blocked legacy web ${key} cleanup rejects B admission before any B token reaches memory`, async () => {
    const f = legacyWebStorageFixture(key); f.seedAccount(); f.block();
    assert.equal((await f.store.load()).user.id, 'A');
    const p = provider({ clear: f.store.clear, save: f.store.save });
    const rejectedLogout = assert.rejects(p.signOut(), /legacy web auth removal blocked/);
    const rejectedLogin = assert.rejects(p.signIn(account('B', 'token-B')), /legacy web auth removal blocked/);
    await Promise.all([rejectedLogout, rejectedLogin]);
    assert.equal(p.current().user.id, 'A'); assert.equal(p.published().user.id, 'A');
    assert.equal((await f.store.load()).user.id, 'A', 'a rejected login cannot partially publish B in the web adapter');
    assert.equal((await f.reload()).user.id, 'A', 'the failed login does not claim B survives reload');
    f.unblock(); await p.signIn(account('B', 'token-B'));
    assert.equal(p.current().user.id, 'B'); assert.equal(p.published().user.id, 'B');
    assert.equal((await f.store.load()).user.id, 'B');
    for (const name of [sessionKey, sessionHistoryKey]) assert.equal(f.data.has(name), false);
    assert.equal(await f.reload(), null, 'successful web login keeps credentials in memory and removes both old durable copies');
  });

  test(`queued B login after legacy web ${key} failure waits for old teardown and removes A before admission`, async () => {
    const f = legacyWebStorageFixture(key); f.seedAccount(); f.block(); await f.store.load();
    const native = deferred(), reached = deferred();
    const p = provider({ clear: f.store.clear, save: f.store.save, disconnect: async () => { reached.resolve(); await native.promise; } });
    const oldGuard = p.guard();
    const rejectedLogout = assert.rejects(p.signOut(), /legacy web auth removal blocked/);
    await reached.promise;
    const login = p.signIn(account('B', 'token-B'));
    assert.equal(p.current().user.id, 'A');
    f.unblock(); native.resolve(); await Promise.all([rejectedLogout, login]);
    assert.equal(oldGuard(), false); assert.equal(p.current().user.id, 'B'); assert.equal(p.published().user.id, 'B');
    assert.equal((await f.store.load()).user.id, 'B'); assert.equal(await f.reload(), null);
  });
}

test('ordinary web cache deletion remains best effort while required auth copies are removed', async () => {
  const f = legacyWebStorageFixture('vex.vpn.hot_profiles.v1'); f.seedAccount(); f.block();
  f.data.set('vex.vpn.hot_profiles.v1', 'fixture');
  const p = provider({ clear: f.store.clear });
  await p.signOut(); assert.equal(p.current(), null); assert.equal(await f.reload(), null);
  assert.equal(f.data.get('vex.vpn.hot_profiles.v1'), 'fixture');
});

test('web primary admission attempts both legacy credential removals before rejecting', async () => {
  const f = legacyWebStorageFixture(sessionKey); f.seedAccount(); f.block();
  await assert.rejects(f.adapter.setItemAsync(sessionKey, JSON.stringify(account('B', 'token-B'))), /legacy web auth removal blocked/);
  assert.ok(f.deletions.includes(sessionKey)); assert.ok(f.deletions.includes(sessionHistoryKey));
  assert.equal(JSON.parse(await f.adapter.getItemAsync(sessionKey)).user.id, 'A', 'no partial B memory write');
});

test('a storage deletion rejection without an Error still leaves logout incomplete', async () => {
  let nativeStops = 0;
  const p = provider({ clear: () => Promise.reject(undefined), disconnect: async () => { nativeStops++; } });
  const [result] = await Promise.allSettled([p.signOut()]);
  assert.equal(result.status, 'rejected'); assert.equal(nativeStops, 1);
  assert.equal(p.current().user.id, 'A'); assert.equal(p.published().user.id, 'A');
});

function rotatingRefreshStorageFixture() {
  const data = new Map(), requests = [];
  let failNextWrite = false, generation = 0;
  const store = createSessionStore({
    getItemAsync: async key => data.get(key) ?? null,
    setItemAsync: async (key, value) => {
      if (failNextWrite && key === sessionKey) { failNextWrite = false; throw new Error('temporary keychain write failure'); }
      data.set(key, value);
    },
    deleteItemAsync: async key => { data.delete(key); }, clearSensitiveStorageHistory: async () => { data.clear(); },
  });
  const refresh = async token => {
    requests.push(token);
    if (token === 'token-A' && generation > 0) throw new ApiRequestError('old token revoked by rotating refresh', { status: 401 });
    generation++;
    return account('A', `token-A-refreshed-${generation}`);
  };
  return { data, requests, store, refresh, failPrimaryWrite: () => { failNextWrite = true; } };
}

test('runtime refresh retains its successful rotating response across a failed save and coalesced retry', async () => {
  const f = rotatingRefreshStorageFixture(); await f.store.save(account('A', 'token-A'));
  const p = provider({ save: f.store.save, clear: f.store.clear, refresh: f.refresh });
  f.failPrimaryWrite(); await assert.rejects(p.refresh(), /temporary keychain write failure/);
  assert.equal(p.current().accessToken, 'token-A');
  const guard = p.guard();
  const retried = p.refresh(), coalesced = p.refresh();
  const [retryResult, coalescedResult] = await Promise.all([retried, coalesced]);
  assert.equal(retryResult.accessToken, 'token-A-refreshed-1');
  assert.equal(coalescedResult.accessToken, 'token-A-refreshed-1');
  assert.deepEqual(f.requests, ['token-A'], 'a successful rotating request must never be sent twice');
  assert.equal(guard(), true, 'same-account refresh keeps its operation ownership');
  assert.equal((await f.store.load()).accessToken, 'token-A-refreshed-1');
  for (const name of [sessionKey, sessionHistoryKey]) assert.equal(JSON.parse(f.data.get(name)).accessToken, 'token-A-refreshed-1');
  assert.equal((await p.refresh()).accessToken, 'token-A-refreshed-2');
  assert.deepEqual(f.requests, ['token-A', 'token-A-refreshed-1'], 'a later genuine refresh uses the new token');
});

test('runtime refresh hands a successful response to the next provider mount after a failed save', async () => {
  const f = rotatingRefreshStorageFixture(); await f.store.save(account('A', 'token-A'));
  const p = provider({ save: f.store.save, clear: f.store.clear, refresh: f.refresh });
  f.failPrimaryWrite(); await assert.rejects(p.refresh(), /temporary keychain write failure/);
  const mounted = restoreHarness({ load: f.store.load, save: f.store.save, clear: f.store.clear, refresh: f.refresh, restoreRefresh: p.restoreRefresh });
  await mounted.restore();
  assert.equal(mounted.state.loading, false); assert.equal(mounted.state.session.accessToken, 'token-A-refreshed-1');
  assert.deepEqual(f.requests, ['token-A']); assert.equal((await f.store.load()).accessToken, 'token-A-refreshed-1');
});

for (const mutation of ['signIn', 'signOut']) {
  test(`${mutation} discards the runtime successful response retained after a failed save`, async () => {
    const f = rotatingRefreshStorageFixture(); await f.store.save(account('A', 'token-A'));
    const p = provider({ save: f.store.save, clear: f.store.clear, refresh: f.refresh });
    f.failPrimaryWrite(); await assert.rejects(p.refresh(), /temporary keychain write failure/);
    if (mutation === 'signIn') await p.signIn(account('B', 'token-B'));
    else await p.signOut();
    const expected = mutation === 'signIn' ? 'B' : null;
    const restored = await f.store.load();
    assert.equal(restored?.user.id ?? null, expected); assert.equal(p.current()?.user.id ?? null, expected);
    let attempts = 0;
    await p.restoreRefresh.run('token-A', async () => { attempts++; return account('A', 'fresh-explicit-A'); });
    assert.equal(attempts, 1, 'the invalidated A handoff is no longer reused');
    assert.equal(p.current()?.user.id ?? null, expected);
  });
}

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
  await flush();
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

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');

const repo = path.resolve(__dirname, '..');
function load(file, dependencies = {}) {
  const code = ts.transpileModule(fs.readFileSync(path.join(repo, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, Error, Date, URLSearchParams, setInterval, clearInterval, require: name => {
    assert.ok(Object.hasOwn(dependencies, name), `unexpected policy import ${name}`);
    return dependencies[name];
  } });
  return exports;
}
const sessionOperation = load('src/vpn/sessionOperation.ts');
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
const paid = { active: true, vpnAccess: true };
const makeProfile = (owner = 'A', extra = {}) => ({
  config: `[Interface]\nPrivateKey = isolated-${owner}\nAddress = 10.0.0.2/32`,
  device: { id: `device-${owner}`, assignedIpv4: '10.0.0.2', provisioningMode: 'managed_native', keyEpoch: 2 },
  locationId: 'de', routingMode: 'default', entitlement: paid, source: 'api', ...extra,
});

function hookHarness(stage, { rotationRequired = false, knownEntitlement = paid } = {}) {
  const gate = deferred(), reached = deferred(), calls = [], slots = [], effects = [];
  let cursor = 0, revision = 0, owner = 'A';
  const wait = async (name, value) => {
    calls.push(name);
    if (stage === name) { reached.resolve(); await gate.promise; }
    return value;
  };
  const react = {
    useCallback: fn => fn, useMemo: fn => fn(), useEffect: fn => effects.push(fn),
    useRef: initial => { const index = cursor++; slots[index] ??= { current: initial }; return slots[index]; },
    useState: initial => {
      const index = cursor++; if (!(index in slots)) slots[index] = initial;
      return [slots[index], value => {
        calls.push(`state:${index}`); slots[index] = typeof value === 'function' ? value(slots[index]) : value;
      }];
    },
  };
  const query = {
    getQueryData: () => undefined, setQueryData: () => calls.push('cache-query'), removeQueries: () => calls.push('remove-query'),
    invalidateQueries: () => wait('invalidate'), fetchQuery: ({ queryFn }) => queryFn(),
  };
  const module = load('src/vpn/useVpnProfileState.ts', {
    react, '@tanstack/react-query': { useQueryClient: () => query }, 'react-native': { Platform: { OS: 'ios' } },
    '@/utils/error': { errorMessage: error => error.message },
    '../api/vexApi': { hasPaidEntitlement: value => Boolean(value?.active), entitlement: () => wait('entitlement', paid) },
    './profile': {
      resetVpnProfileCache: () => calls.push('reset-cache'),
      resolveVpnProfile: (...args) => { assert.equal(typeof args[3].isCurrentSessionOperation, 'function'); return wait('resolve', makeProfile(owner, { rotationRequired, locationId: args[2] })); },
      rotateVpnProfileKey: (...args) => { assert.equal(typeof args[2], 'function'); return wait('rotate', makeProfile()); },
    },
    './profileRequestQueue': { ProfileRequestSupersededError: class ProfileRequestSupersededError extends Error {} },
    './sessionOperation': sessionOperation,
    './hotProfileCache': {
      clearHotVpnProfiles: () => wait('clear-hot'), hydrateHotVpnProfilesToQueryCache: async () => [],
      loadHotVpnProfileResult: () => wait('hot', { record: null }), profileFromHotRecord: record => record.profile,
      saveHotVpnProfile: async () => { calls.push('save-hot'); },
    },
    './connectFlow': { connectableLocalProfile: (profile, location, entitlement) => profile?.locationId === location && entitlement?.active ? profile : null },
    './androidRoutingSafety': { androidVpnProfileRequiresRefresh: () => false, androidVpnProfileWithinBinderBudget: () => true },
  });
  function render(userId = owner, accessToken = `token-${userId}`) {
    cursor = 0; effects.length = 0;
    const expectedRevision = revision;
    const isCurrentSessionOperation = () => expectedRevision === revision && userId === owner;
    return module.useVpnProfileState({
      accessToken, userId, isCurrentSessionOperation, hasVpnAccess: true, knownEntitlement,
      selectedLocationId: 'de', routingMode: 'default', realtimeConnected: true, profileRefreshMs: 60_000,
      requestVpnPermission: () => wait('permission', true), onDeviceRevoked: async () => { calls.push('native-revoke'); },
      onProfileRefreshFailed: () => calls.push('refresh-failed'), onProfileRotationRequired: () => calls.push('rotation-required'),
      onSubscriptionRequired: () => calls.push('subscription-required'),
    });
  }
  return { calls, gate, reached, render, effects, supersede: () => { revision++; owner = 'B'; } };
}

for (const outcome of ['resolve', 'reject']) {
  test(`manual rotation late ${outcome} cannot publish/cache A or unlock B`, async () => {
    const h = hookHarness('rotate'), state = h.render();
    const pending = state.rotateActiveProfile(makeProfile(), 'de');
    const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED' || error.message === 'late failure');
    await h.reached.promise; h.supersede(); const before = h.calls.slice();
    if (outcome === 'resolve') h.gate.resolve(); else h.gate.reject(new Error('late failure'));
    await rejected; assert.deepEqual(h.calls, before);
  });
}

for (const stage of ['hot', 'entitlement', 'permission', 'resolve', 'rotate']) {
  test(`foreground profile preparation during ${stage} stops old-account mutations after session change`, async () => {
    const h = hookHarness(stage, { rotationRequired: stage === 'rotate', knownEntitlement: stage === 'entitlement' ? null : paid });
    const state = h.render();
    const pending = state.resolveConnectableVpnProfile('de', { forceRefresh: stage !== 'hot' });
    const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    await h.reached.promise; h.supersede(); const before = h.calls.slice(); h.gate.resolve(); await rejected;
    assert.deepEqual(h.calls, before, 'no subsequent permission, rotation, cache, subscription or UI mutations');
  });
}

for (const stage of ['invalidate', 'clear-hot']) {
  test(`late device revocation during ${stage} cannot disconnect B`, async () => {
    const h = hookHarness(stage), state = h.render(); state.setActiveProfile(makeProfile());
    const pending = state.refreshManagedProfile({ reason: 'device_revoked', device_id: 'device-A' });
    await h.reached.promise; h.supersede(); const before = h.calls.slice(); h.gate.resolve(); await pending;
    assert.deepEqual(h.calls, before); assert.ok(!h.calls.includes('native-revoke'));
  });
}

test('B cannot use A active profile as a local fallback before passive owner reset effects run', async () => {
  const h = hookHarness(null); const stateA = h.render(); stateA.setActiveProfile(makeProfile());
  assert.equal(h.render().activeProfile.device.id, 'device-A');
  h.supersede(); const stateB = h.render('B'); assert.equal(stateB.activeProfile, null);
  const before = h.calls.length; const resolved = await stateB.resolveConnectableVpnProfile('de', { requestPermission: false });
  assert.equal(resolved.device.id, 'device-B'); assert.ok(h.calls.slice(before).includes('resolve'));
  const after = h.calls.slice(); stateA.setActiveProfile(makeProfile()); stateA.cacheProfile('de', makeProfile()); stateA.clearProfile();
  assert.deepEqual(h.calls, after, 'retained setters/clear cannot mutate the new login');
});

test('current session manual rotation remains usable and persists its own profile', async () => {
  const h = hookHarness(null), state = h.render(); await state.rotateActiveProfile(makeProfile(), 'de');
  assert.equal(h.render().activeProfile.device.id, 'device-A'); assert.ok(h.calls.includes('cache-query'));
});

test('same-account token refresh during manual rotation preserves the current owner', async () => {
  const h = hookHarness('rotate'), state = h.render();
  const pending = state.rotateActiveProfile(makeProfile(), 'de'); await h.reached.promise;
  h.render('A', 'token-A-refreshed'); h.gate.resolve(); await pending;
  assert.equal(h.render('A', 'token-A-refreshed').activeProfile.device.id, 'device-A');
});

test('B background functional update cannot retain and relabel an A profile from another location', async () => {
  const h = hookHarness(null), stateA = h.render(); stateA.setActiveProfile(makeProfile('A'));
  h.supersede(); const stateB = h.render('B');
  await stateB.resolveConnectableVpnProfile('fi', { cachedProfile: makeProfile('B', { locationId: 'fi' }), requestPermission: false });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.render('B').activeProfile, null, 'the background updater must receive null for an unowned previous state');
});

test('a superseded profile response cannot seed the global cache for a later login', async () => {
  const gate = deferred(), reached = deferred(); let current = true, requests = 0;
  const module = load('src/vpn/profile.ts', {
    '../api/vexApi': {
      hasPaidEntitlement: value => value.active,
      preparedTunnel: async (_, __, options) => {
        assert.equal(typeof options.isCurrentSessionOperation, 'function'); requests++;
        if (requests === 1) { reached.resolve(); await gate.promise; return makeProfile('A'); }
        return makeProfile('B');
      },
    },
    './hotProfileCache': {},
    './routingPolicy': { defaultVpnRoutingMode: 'default', defaultVpnBypassRegion: 'ru', defaultVpnRoutingPolicyVersion: 'v1' },
    './profileRequestQueue': { runProfileRequest: operation => operation() },
    './profileConsistency': { vpnProfileAddressMatchesDevice: () => true },
    './locationId': { requireVpnLocationId: value => value }, './profileRevalidation': { profileRevalidationOptions: () => ({}) },
    './sessionOperation': sessionOperation,
  });
  const pending = module.resolveVpnProfile('fixture-token', paid, 'de', { forceRefresh: true, isCurrentSessionOperation: () => current });
  const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  await reached.promise; current = false; gate.resolve(); await rejected;
  const profileB = await module.resolveVpnProfile('fixture-token', paid, 'de', { isCurrentSessionOperation: () => true });
  assert.equal(profileB.device.id, 'device-B'); assert.equal(requests, 2, 'late A must not populate the global fast path');
});

function vpnApi(operations) {
  return load('src/api/vpn.ts', {
    'react-native': { Platform: { OS: 'android' } }, '@/native/appInfo': { getOrCreateDeviceId: async () => 'installation-fixture' }, '@/native/deviceIdentity': {},
    '@/native/vexVpn': operations.native, '@/vpn/nativeDeviceSelection': { nativeVpnDeviceForClient: devices => devices[0] },
    '@/vpn/keyEpochRecovery': { nextManagedKeyEpoch: (_, epoch) => (epoch ?? 0) + 1, isKeyEpochMismatchError: error => error.code === 'epoch_mismatch' },
    '@/vpn/routingPolicy': { defaultVpnRoutingMode: 'default', defaultVpnRoutingPolicyVersion: 'v1', resolvedVpnBypassRegion: () => '' },
    '@/notifications/pushRegistration': {}, './client': operations.client, './error': { ApiRequestError: class ApiRequestError extends Error {} },
    './auth': { me: async () => ({ id: 'fixture-owner' }) },
    '../native/vpnAccountIdentity': {
      getOrCreateVpnAccountIdentity: async () => ({ installationId: 'installation-fixture', externalDeviceId: 'installation-fixture', keyScope: 'fixture-scope', keyPair: await operations.native.getOrCreateWireGuardKeyPair() }),
      withVpnAccountIdentity: async (_, callback) => callback({ keyScope: 'fixture-scope' }),
      saveVpnAccountKeyPair: async () => operations.native.replaceWireGuardKeyPair(),
    },
    './deviceCreateRequest': {}, './clientDiagnosticsRequest': {}, './nativeDeviceRegistration': {},
    '../vpn/amneziaConfig': {}, '../vpn/profileCapabilities': { withManagedProfileAWGCapability: query => query },
    '../vpn/locationCatalog': {}, '../vpn/locationId': { requireVpnLocationId: value => value }, '../vpn/profileRevalidation': {},
    '../vpn/sessionOperation': sessionOperation,
  });
}

for (const stage of ['generate', 'api']) {
  test(`late explicit API key rotation during ${stage} cannot replace B shared native keypair`, async () => {
    const gate = deferred(), reached = deferred(), calls = []; let current = true;
    const wait = async (name, value) => { calls.push(name); if (stage === name) { reached.resolve(); await gate.promise; } return value; };
    const api = vpnApi({
      native: { generateWireGuardKeyPair: () => wait('generate', { publicKey: 'key-A', keyEpoch: 2 }), replaceWireGuardKeyPair: async () => calls.push('replace-native-key') },
      client: { jsonRequest: () => wait('api', { device: { id: 'device-A' } }) },
    });
    const pending = api.rotateManagedVpnKey('token-A', 'device-A', 2, () => current);
    const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    await reached.promise; current = false; const before = calls.slice(); gate.resolve(); await rejected;
    assert.deepEqual(calls, before); assert.ok(!calls.includes('replace-native-key'));
  });
}

test('implicit key epoch recovery carries owner guard to native key replacement', async () => {
  const gate = deferred(), reached = deferred(), calls = []; let current = true;
  const api = vpnApi({
    native: { getOrCreateWireGuardKeyPair: async () => ({ publicKey: 'key-A', keyEpoch: 1 }), generateWireGuardKeyPair: async () => ({ publicKey: 'new-key-A', keyEpoch: 1 }), replaceWireGuardKeyPair: async () => calls.push('replace-native-key') },
    client: {
      clientVersionHeaders: async () => ({}),
      jsonRequest: async path => {
        calls.push(path);
        if (path === '/v1/devices') return [{ id: 'device-A', status: 'active', public_key: 'placeholder', provisioning_mode: 'managed_native', psk_epoch: 2 }];
        if (calls.filter(value => value === '/v1/vpn/rotate-key').length === 1) throw Object.assign(new Error('epoch mismatch'), { code: 'epoch_mismatch' });
        reached.resolve(); await gate.promise; return { device: { id: 'device-A', public_key: 'new-key-A', psk_epoch: 3 } };
      },
    },
  });
  const pending = api.preparedTunnel('token-A', { platform: 'android', deviceName: 'fixture', idempotencyPrefix: 'fixture' }, { locationId: 'de', isCurrentSessionOperation: () => current });
  const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  await reached.promise; current = false; const before = calls.slice(); gate.resolve(); await rejected;
  assert.deepEqual(calls, before); assert.ok(!calls.includes('replace-native-key'));
  assert.equal(calls.filter(value => value === '/v1/vpn/rotate-key').length, 2, 'the real epoch mismatch path reached transactional recovery');
});

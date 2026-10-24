const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const ts = require('typescript');

const repo = path.resolve(__dirname, '..');
function load(file, dependencies = {}) {
  const overlay = process.env.VEX_PROFILE_NUMERIC_SOURCE_ROOT && path.join(process.env.VEX_PROFILE_NUMERIC_SOURCE_ROOT, file);
  const source = file === 'src/api/vpn.ts' && process.env.VEX_STAGED_PROFILE_SOURCE || (overlay && fs.existsSync(overlay) ? overlay : path.join(repo, file));
  const code = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
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
const apiErrors = load('src/api/error.ts');
const cancellation = load('src/api/requestCancellation.ts', { './error': apiErrors });
const profileNumbers = fs.existsSync(path.join(repo, 'src/vpn/profileNumbers.ts')) ? load('src/vpn/profileNumbers.ts') : {};
const epochRecovery = load('src/vpn/keyEpochRecovery.ts', { './profileNumbers': profileNumbers });
const pskEvents = load('src/vpn/devicePskRotation.ts', { './profileNumbers': profileNumbers });
const profileCore = load('src/vpn/hotProfileCacheCore.ts', { './locationId': load('src/vpn/locationId.ts') });
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
    '../hooks/useOwnedState': load('src/hooks/useOwnedState.ts', { react }),
    react, '@tanstack/react-query': { useQueryClient: () => query, isCancelledError: () => false },
    'react-native': { Platform: { OS: 'ios' } },
    '@/utils/error': { errorMessage: error => error.message },
    '../api/vexApi': { vpnProfileKeyIsCurrent: async () => true, hasPaidEntitlement: value => Boolean(value?.active), entitlement: () => wait('entitlement', paid) },
    './profile': {
      resetVpnProfileCache: () => calls.push('reset-cache'),
      resolveVpnProfile: (...args) => { assert.equal(typeof args[3].isCurrentSessionOperation, 'function'); return wait('resolve', makeProfile(owner, { rotationRequired, locationId: args[2] })); },
      rotateVpnProfileKey: (...args) => { assert.equal(typeof args[2], 'function'); return wait('rotate', makeProfile()); },
    },
    './profileRequestQueue': { ProfileRequestSupersededError: class ProfileRequestSupersededError extends Error {} },
    '../api/error': apiErrors, '../api/requestCancellation': cancellation,
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
      vpnProfileKeyIsCurrent: async () => true,
      hasPaidEntitlement: value => value.active,
      preparedTunnel: async (_, __, options) => {
        assert.equal(typeof options.isCurrentSessionOperation, 'function'); requests++;
        if (requests === 1) { reached.resolve(); await gate.promise; return makeProfile('A'); }
        return makeProfile('B');
      },
    },
    './hotProfileCache': {},
    './hotProfileCacheCore': profileCore,
    './profileNumbers': profileNumbers,
    './routingPolicy': { defaultVpnRoutingMode: 'default', defaultVpnBypassRegion: 'ru', defaultVpnRoutingPolicyVersion: 'v1' },
    './profileRequestQueue': { runProfileRequest: operation => operation() },
    './profileConsistency': { vpnProfileAddressMatchesDevice: () => true },
    './locationId': { requireVpnLocationId: value => value }, './profileRevalidation': { profileRevalidationOptions: () => ({}) },
    '../api/error': apiErrors, '../api/requestCancellation': cancellation,
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
    '@/native/vexVpn': { supportsNativeRoutingPolicy: () => false, ...operations.native }, '@/vpn/nativeDeviceSelection': { nativeVpnDeviceForClient: devices => devices[0] },
    '@/vpn/keyEpochRecovery': operations.epochRecovery ?? { nextManagedKeyEpoch: (_, epoch) => (epoch ?? 0) + 1, isKeyEpochMismatchError: error => error.code === 'epoch_mismatch' },
    '@/vpn/routingPolicy': { defaultVpnRoutingMode: 'default', defaultVpnRoutingPolicyVersion: 'v1', resolvedVpnBypassRegion: () => '' },
    '@/notifications/pushRegistration': {}, './client': operations.client, './error': apiErrors, './requestCancellation': cancellation,
    './auth': { me: async () => ({ id: 'fixture-owner' }) },
    '../native/vpnAccountIdentity': {
      getOrCreateVpnAccountIdentity: async () => ({ installationId: 'installation-fixture', externalDeviceId: 'installation-fixture', keyScope: 'fixture-scope', keyPair: await operations.native.getOrCreateWireGuardKeyPair() }),
      withVpnAccountIdentity: async (_, callback) => { operations.observe?.('account'); return callback({ keyScope: 'fixture-scope', keyPair: { publicKey: 'fixture-old-key', keyEpoch: 1 } }); },
      saveVpnAccountKeyPair: async () => operations.native.replaceWireGuardKeyPair(),
      pendingVpnAccountKeyPair: async () => undefined,
      rememberVpnAccountDevice: async (options, identity, confirmedDeviceId) => {
        if (options.isCurrentSessionOperation && !options.isCurrentSessionOperation()) throw new sessionOperation.SessionOperationSupersededError();
        return { ...identity, confirmedDeviceId };
      },
      savePendingVpnAccountKeyPair: async () => undefined,
      clearPendingVpnAccountKeyPair: async () => undefined,
    },
    './deviceCreateRequest': {}, './clientDiagnosticsRequest': {}, './nativeDeviceRegistration': {},
    '../vpn/amneziaConfig': {}, '../vpn/profileCapabilities': { withManagedProfileAWGCapability: query => query },
    '../vpn/locationCatalog': {}, '../vpn/locationId': { requireVpnLocationId: value => value }, '../vpn/profileRevalidation': {},
    '../vpn/sessionOperation': sessionOperation,
    '../vpn/nativeRoutingPolicy': {},
    '../vpn/profileNumbers': profileNumbers,
  });
}

for (const value of [null, '2', NaN, Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER + 1]) {
  test(`invalid or overflowing server epoch ${String(value)} cannot dispatch rotation or replace a key`, async () => {
    let requests = 0, replacements = 0, generations = 0, setup = 0;
    const api = vpnApi({ epochRecovery, observe: () => { setup++; }, native: { generateWireGuardKeyPair: async () => { generations++; return { publicKey: 'fixture-key', keyEpoch: 2 }; }, replaceWireGuardKeyPair: async () => { replacements++; } },
      client: { jsonRequest: async () => { requests++; throw new Error('unexpected fixture mutation'); } } });
    await assert.rejects(api.rotateManagedVpnKey('fixture-token', 'device-A', value, () => true), /эпох|epoch/i);
    assert.equal(requests, 0); assert.equal(replacements, 0); assert.equal(generations, 0); assert.equal(setup, 0);
  });
}

test('epoch calculation retains legacy zero/missing and exact safe boundary behavior', () => {
  assert.equal(epochRecovery.nextManagedKeyEpoch(undefined, undefined), 1);
  assert.equal(epochRecovery.nextManagedKeyEpoch(0, 0), 1);
  assert.equal(epochRecovery.nextManagedKeyEpoch(8, 5), 6);
  assert.equal(epochRecovery.nextManagedKeyEpoch(2, Number.MAX_SAFE_INTEGER - 1), Number.MAX_SAFE_INTEGER);
  assert.equal(epochRecovery.nextManagedKeyEpoch(Number.MAX_SAFE_INTEGER), Number.MAX_SAFE_INTEGER);
  for (const value of [NaN, Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => epochRecovery.nextManagedKeyEpoch(value), /эпох|epoch/i);
  }
});

test('rotation uses independent material only when an authoritative epoch is available', async () => {
  for (const serverEpoch of [undefined, 0, 5]) {
    const expected = serverEpoch === undefined ? 7 : serverEpoch + 1; let posts = 0, saves = 0;
    const api = vpnApi({ epochRecovery, native: {
      generateWireGuardKeyPair: async options => {
        assert.equal(options.independentEpoch, serverEpoch !== undefined);
        return { publicKey: 'fixture-new-key', keyEpoch: options.independentEpoch ? 1 : 7 };
      }, replaceWireGuardKeyPair: async () => { saves++; },
    }, client: { jsonRequest: async (requestPath, options) => {
      if (requestPath === '/v1/devices') return [{ id: 'fixture-device', public_key: 'fixture-old-key', psk_epoch: serverEpoch }];
      assert.equal(requestPath, '/v1/vpn/rotate-key'); assert.equal(options.body.key_epoch, expected); posts++;
      return { device: { id: 'fixture-device', public_key: 'fixture-new-key', psk_epoch: expected } };
    } } });
    assert.equal((await api.rotateManagedVpnKey('fixture-token', 'fixture-device', serverEpoch, () => true, 'owner')).keyEpoch, expected);
    assert.equal(posts, 1); assert.equal(saves, 1);
  }
});

const numericEvent = version => ({ event_id: 'fixture-event', type: 'profile_updated', device_id: 'fixture-device', rotation_id: 'fixture-rotation', profile_version: version });
for (const version of ['7junk', '7.5', '7e3', '+7', [7], { toString: () => '7' }, Number.MAX_SAFE_INTEGER + 1, '9007199254740993']) {
  test(`push profile identity rejects partial/coerced version ${String(version)}`, async () => {
    for (const type of ['profile_updated', 'cutover_ready']) {
      const event = pskEvents.parseDevicePSKRotationEvent({ ...numericEvent(version), type }), calls = [];
      if (event) {
        const staged = { deviceId: event.deviceId, rotationId: event.rotationId, profileVersion: event.profileVersion, profileDigest: 'fixture', profile: { profileVersion: event.profileVersion } };
        const record = action => async () => { calls.push(action); return staged; };
        await pskEvents.processDevicePSKRotationEvent(event, event.deviceId, { load: record('load'), fetch: record('fetch'), save: record('save'), acknowledge: record('ack'), activate: record('activate'), clear: record('clear') });
      }
      assert.deepEqual(calls, []); assert.equal(event, null);
    }
  });
}

test('push profile identity retains safe numbers and whole decimal legacy strings', () => {
  for (const version of [7, '7', ' 007 ', Number.MAX_SAFE_INTEGER, String(Number.MAX_SAFE_INTEGER)]) {
    assert.equal(pskEvents.parseDevicePSKRotationEvent(numericEvent(version)).profileVersion, Number(version));
  }
});

test('an invalid direct rotation event cannot bypass parser validation', async () => {
  const calls = [], event = { eventId: 'fixture', type: 'cutover_ready', deviceId: 'fixture-device', rotationId: 'fixture', profileVersion: Number.MAX_SAFE_INTEGER + 1 };
  const dependency = async () => { calls.push('unexpected'); };
  assert.equal(await pskEvents.processDevicePSKRotationEvent(event, event.deviceId, { load: dependency, fetch: dependency, save: dependency, acknowledge: dependency, activate: dependency, clear: dependency }), 'ignored');
  assert.deepEqual(calls, []);
});

for (const epoch of [null, '2', NaN, Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
  test(`device API rejects explicit malformed epoch ${String(epoch)}`, () => {
    const api = vpnApi({ native: {}, client: {} });
    assert.throws(() => api.parseDevice({ id: 'fixture-device', psk_epoch: epoch }), /эпох|epoch/i);
  });
}

test('device API preserves missing and zero legacy epochs without narrowing exact safe values', () => {
  const api = vpnApi({ native: {}, client: {} });
  for (const epoch of [undefined, 0, 1, Number.MAX_SAFE_INTEGER]) assert.equal(api.parseDevice({ id: 'fixture-device', psk_epoch: epoch }).keyEpoch, epoch);
});

for (const version of [null, '7', NaN, Infinity, 0, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
  test(`equal malformed staged versions ${String(version)} cannot acquire keys or authorize a stage`, async () => {
    let reads = 0, requests = 0;
    const api = vpnApi({ native: { getOrCreateWireGuardKeyPair: async () => { reads++; return { publicKey: 'fixture' }; } }, client: { clientVersionHeaders: async () => ({}), jsonRequest: async () => {
      requests++; return { activate: false, profile_version: version, profile: { version, config: 'fixture' } };
    } } });
    await assert.rejects(api.fetchStagedDevicePSKProfile('fixture-token', makeProfile(), 'owner', () => true), /staged/i);
    assert.equal(requests, 1); assert.equal(reads, 0);
  });
}

test('validated staged configuration gets a fresh receipt instead of inheriting old profile age', async () => {
  let requests = 0;
  const module = vpnApi({
    native: { getOrCreateWireGuardKeyPair: async () => ({ publicKey: 'fixture-public', keyEpoch: 2 }) },
    client: { clientVersionHeaders: async () => ({}), jsonRequest: async requestPath => {
      assert.match(requestPath, /^\/v1\/vpn\/psk-rotations\/current\?/); requests++;
      return { activate: false, profile_version: 7, rotation_id: 'fixture-rotation', profile_digest: 'fixture-digest',
        profile: { version: 7, config: 'fresh staged configuration', device_id: 'device-A', client_public_key: 'fixture-public', client_key_epoch: 2 } };
    } },
  });
  const before = Date.now();
  const result = await module.fetchStagedDevicePSKProfile('fixture-token', makeProfile('A', { cacheSavedAtMs: 1 }), 'owner', () => true);
  assert.equal(requests, 1); assert.equal(result.profile.config, 'fresh staged configuration');
  assert.ok(result.profile.cacheSavedAtMs >= before && result.profile.cacheSavedAtMs <= Date.now());
});

for (const stage of ['generate', 'api']) {
  test(`late explicit API key rotation during ${stage} cannot replace B shared native keypair`, async () => {
    const gate = deferred(), reached = deferred(), calls = []; let current = true;
    const wait = async (name, value) => { calls.push(name); if (stage === name) { reached.resolve(); await gate.promise; } return value; };
    const api = vpnApi({
      native: { generateWireGuardKeyPair: () => wait('generate', { publicKey: 'key-A', keyEpoch: 2 }), replaceWireGuardKeyPair: async () => calls.push('replace-native-key') },
      client: { jsonRequest: path => path === '/v1/devices'
        ? Promise.resolve([{ id: 'device-A', public_key: 'key-A', psk_epoch: 2 }])
        : wait('api', { device: { id: 'device-A' } }) },
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

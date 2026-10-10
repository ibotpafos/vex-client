const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const { test } = require('node:test');
const { Buffer } = require('node:buffer');

const sourceRoot = process.env.VEX_MOBILE_REGISTRATION_SOURCE_ROOT || path.resolve(__dirname, '..');
function load(file, names, stubs = {}) {
  const source = stripTypeScriptTypes(fs.readFileSync(path.join(sourceRoot, file), 'utf8'))
    .replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm, '').replace(/\bexport /g, '');
  return new Function(...Object.keys(stubs), source + `;return {${names}};`)(...Object.values(stubs));
}
const key = byte => Buffer.alloc(32, byte).toString('base64');
const legacyPair = { publicKey: key(1), privateKey: key(2), keyEpoch: 1 };
const legacyId = 'vexd_legacy-installation';
const gate = () => { let resolve; const promise = new Promise(ok => { resolve = ok; }); return { promise, resolve }; };

function harness(platform = 'ios', existingStore) {
  const saved = existingStore || new Map([['vex.auth.device_id', legacyId]]);
  const devices = new Map(), bindings = new Map([[legacyId, 'A']]), registrations = [], writes = [], requests = [];
  let generations = 0, lookupFailure = false, writeFailure = false, readFailure = false, markerFailure = false, interruptedConfirmation, removeLegacyBeforeRegistration = false, registerError, holdLookup, holdProfile, profileReached, stagedEpoch, legacyReplacementAllowed = false;
  let globalPair = { ...legacyPair };
  const store = {
    getItemAsync: async storageKey => { if (readFailure && storageKey.startsWith('vex.vpn.account_')) throw Error('locked'); return saved.get(storageKey) ?? null; },
    setItemAsync: async (storageKey, value) => { writes.push(storageKey); if ((writeFailure && storageKey.startsWith('vex.vpn.account_')) || (markerFailure && storageKey === 'vex.vpn.legacy_key_owner.v1')) throw Error('persistence'); if (interruptedConfirmation === 'confirmation' && storageKey.startsWith('vex.vpn.account_registration') && JSON.parse(value).legacyRegistrationPending === false) throw Error('confirmation storage lost'); saved.set(storageKey, value); },
    deleteItemAsync: async storageKey => { saved.delete(storageKey); },
  };
  const app = load('src/native/appInfo.ts', 'getOrCreateDeviceId,getAppInfo,createInstallationUUID', { SecureStore: store, Application: {}, Platform: { OS: platform }, getOtaProvenance: () => ({}) });
  const signer = load('src/native/deviceIdentity.ts', 'getOrCreateDeviceIdentity,deviceIdentitySignaturePayload', { SecureStore: store });
  const session = load('src/vpn/sessionOperation.ts', 'SessionOperationSupersededError');
  const native = { getOrCreateWireGuardKeyPair: async () => ({ ...globalPair }), generateWireGuardKeyPair: async () => ({ publicKey: key(10 + ++generations), privateKey: key(90 + generations), keyEpoch: 2 }), replaceWireGuardKeyPair: async pair => { if (!legacyReplacementAllowed) throw Error('Global key must not be replaced'); globalPair = pair; } };
  const scoped = fs.existsSync(path.join(sourceRoot, 'src/native/vpnAccountIdentity.ts'))
    ? load('src/native/vpnAccountIdentity.ts', 'getOrCreateVpnAccountIdentity,withVpnAccountIdentity,saveVpnAccountKeyPair,pendingVpnAccountKeyPair,savePendingVpnAccountKeyPair,clearPendingVpnAccountKeyPair,renewVpnAccountInstallation,confirmVpnAccountRegistration,vpnAccountRegistrationIdempotencyKey,validatedVpnAccountKeyPair', { SecureStore: store, ...app, ...native, ...session }) : {};
  const location = load('src/vpn/locationId.ts', 'requireVpnLocationId,comparableVpnLocationId');
  const selection = load('src/vpn/nativeDeviceSelection.ts', 'nativeVpnDeviceForClient', location);
  const { ApiRequestError } = load('src/api/error.ts', 'ApiRequestError');
  const ownerFor = token => token === 'refreshed-A' ? 'A' : token;
  const dto = (owner, extra = {}) => ({ id: `device-${owner}`, user_id: owner, status: 'active', protocol: 'amneziawg', platform, provisioning_mode: 'managed_native', client_key_ownership: 'client', external_device_id: legacyId, public_key: legacyPair.publicKey, psk_epoch: 1, ...extra });
  const profile = device => ({ device_id: device.id, assigned_ipv4: '10.0.0.2/32', server: 'fixture.example', port: 443, server_public_key: key(4), client_public_key: device.public_key, client_key_epoch: device.psk_epoch, preshared_key: key(device.psk_epoch + 20), version: 1 });
  devices.set('A', [dto('A')]);
  const jsonRequest = async (requestPath, options) => {
    requests.push(requestPath); const owner = ownerFor(options.accessToken);
    if (requestPath === '/v1/devices') { if (lookupFailure) throw Error('lookup unavailable'); if (holdLookup) await holdLookup.promise; return devices.get(owner) || []; }
    if (requestPath === '/v1/devices/identity-challenge') { if (interruptedConfirmation === 'challenge') throw Error('challenge unavailable'); return { id: `challenge-${registrations.length}-${owner}`, nonce: `nonce-${owner}`, purpose: 'register' }; }
    if (requestPath === '/v1/devices/register') {
      const body = options.body; registrations.push({ owner, body, idempotency: options.idempotencyKey });
      const publicKey = await crypto.subtle.importKey('jwk', JSON.parse(body.identity_public_key), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      const payload = signer.deviceIdentitySignaturePayload({ id: body.identity_challenge_id, nonce: `nonce-${owner}`, purpose: 'register' }, body.installation_id, body.identity_public_key, body.public_key);
      assert.equal(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, Buffer.from(body.identity_signature, 'base64url'), new TextEncoder().encode(payload)), true);
      if (registerError) throw registerError;
      if (removeLegacyBeforeRegistration && owner === 'B') { devices.set('B', []); removeLegacyBeforeRegistration = false; }
      // The real replay guard reads the current row indexed by its creation
      // header and rejects a stale request public key or authoritative epoch.
      const indexed = (devices.get(owner) || []).find(device => device.fixture_creation_key === options.idempotencyKey);
      if (indexed && (indexed.public_key !== body.public_key || indexed.psk_epoch !== body.key_epoch)) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
      if (bindings.has(body.installation_id) && bindings.get(body.installation_id) !== owner) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
      const existing = (devices.get(owner) || []).find(device => device.status === 'active' && device.external_device_id === body.device_id);
      const device = existing || dto(owner, { id: `registered-${owner}-${registrations.length}`, external_device_id: body.device_id, public_key: body.public_key, psk_epoch: body.key_epoch, fixture_creation_key: options.idempotencyKey });
      if (!existing) devices.set(owner, [...(devices.get(owner) || []), device]);
      bindings.set(body.installation_id, owner); if (interruptedConfirmation === 'register') throw Error('registration response lost'); return { device };
    }
    if (requestPath === '/v1/vpn/rotate-key') {
      const device = (devices.get(owner) || []).find(item => item.id === options.body.device_id);
      if (options.body.key_epoch !== device.psk_epoch + 1) throw new ApiRequestError('key_epoch does not match next device epoch', { status: 409, code: 'conflict' });
      if (interruptedConfirmation === 'rotate') {
        const pending = [...saved.entries()].find(([storageKey]) => storageKey.endsWith('.pending'));
        assert.ok(pending, 'repair private pair must be durable before rotation POST');
        assert.equal(JSON.parse(pending[1]).publicKey, options.body.public_key);
        device.public_key = options.body.public_key; device.psk_epoch = options.body.key_epoch; throw Error('rotation response lost');
      }
      device.public_key = options.body.public_key; device.psk_epoch = options.body.key_epoch; return { device };
    }
    if (requestPath.startsWith('/v1/vpn/profile?')) {
      if (holdProfile) { profileReached.resolve(); await holdProfile.promise; }
      return profile((devices.get(owner) || []).find(device => device.id === new URLSearchParams(requestPath.split('?')[1]).get('device_id')));
    }
    if (requestPath.startsWith('/v1/vpn/psk-rotations/current?')) {
      const device = (devices.get(owner) || []).find(item => item.id === new URLSearchParams(requestPath.split('?')[1]).get('device_id'));
      return { activate: false, profile_version: 1, profile: profile(stagedEpoch === undefined ? device : { ...device, psk_epoch: stagedEpoch }), rotation_id: 'rotation', profile_digest: 'digest' };
    }
    throw Error(`Unexpected API route ${requestPath}`);
  };
  const api = load('src/api/vpn.ts', 'preparedTunnel,rotateManagedVpnKey,fetchStagedDevicePSKProfile', {
    Platform: { OS: platform }, ...app, ...signer, ...native, ...scoped, ...location, ...selection, ...session,
    ...load('src/api/nativeDeviceRegistration.ts', 'getOrCreateNativeDeviceRegistration'),
    ...load('src/vpn/keyEpochRecovery.ts', 'nextManagedKeyEpoch,isKeyEpochMismatchError'),
    ...load('src/vpn/amneziaConfig.ts', 'managedProfileAmneziaConfig'),
    ...load('src/vpn/profileRevalidation.ts', 'canRevalidateDevice'),
    me: async token => ({ id: ownerFor(token) }), clientVersionHeaders: async () => ({}), jsonRequest, ApiRequestError,
    defaultVpnRoutingMode: 'default', defaultVpnRoutingPolicyVersion: 'v1', resolvedVpnBypassRegion: () => '', withManagedProfileAWGCapability: query => query,
  });
  return { api, scoped, saved, devices, bindings, registrations, requests, writes, dto, generations: () => generations,
    setLookupFailure: value => { lookupFailure = value; }, setWriteFailure: value => { writeFailure = value; }, setReadFailure: value => { readFailure = value; }, setRegisterError: value => { registerError = value; }, holdLookup: value => { holdLookup = value; }, ApiRequestError,
    holdProfile: (value, reached) => { holdProfile = value; profileReached = reached; }, allowLegacyReplacement: () => { legacyReplacementAllowed = true; },
    setMarkerFailure: value => { markerFailure = value; },
    interruptConfirmation: value => { interruptedConfirmation = value; },
    removeLegacyBeforeRegister: () => { removeLegacyBeforeRegistration = true; },
    setStagedEpoch: value => { stagedEpoch = value; },
    prepare: (owner, options = {}) => api.preparedTunnel(owner, { platform, deviceName: platform, idempotencyPrefix: platform }, { userId: ownerFor(owner), locationId: 'de', isCurrentSessionOperation: () => true, ...options }),
  };
}

for (const platform of ['android', 'ios']) test(`${platform}: A logout → B login → A keeps distinct logical identities and one A device`, async () => {
  const h = harness(platform);
  const a = await h.prepare('A'), b = await h.prepare('B'), again = await h.prepare('refreshed-A');
  assert.equal(a.device.id, 'device-A'); assert.equal(again.device.id, a.device.id);
  assert.notEqual(b.device.externalDeviceId, legacyId); assert.notEqual(b.device.publicKey, a.device.publicKey);
  assert.equal(h.devices.get('A').length, 1); assert.equal(h.devices.get('B').length, 1); assert.equal(h.registrations.length, 2);
  assert.match(again.config, new RegExp(legacyPair.privateKey.replace(/[+]/g, '\\+')));
  assert.equal(await h.scoped.getOrCreateVpnAccountIdentity({ userId: 'B', platform, locationId: 'de', loadOwnedDevices: async () => [] }).then(identity => identity.keyPair.publicKey), b.device.publicKey);
  assert.equal(h.saved.get('vex.auth.device_id'), legacyId); assert.equal(h.generations(), 1);
});

test('B-first legacy binding confirmation separates B before unmigrated A connects', async () => {
  const h = harness(); h.devices.set('B', [h.dto('B')]);
  assert.equal(h.saved.has('vex.vpn.legacy_key_owner.v1'), false);
  const aBefore = JSON.stringify(h.devices.get('A'));
  const b = await h.prepare('B');
  assert.notEqual(b.device.publicKey, legacyPair.publicKey, 'B must separate the global WG key immediately, before A migrates');
  assert.ok(!b.config.includes(`PrivateKey = ${legacyPair.privateKey}`));
  assert.equal(b.device.id, 'device-B'); assert.equal(h.devices.get('B').length, 1);
  assert.equal(JSON.stringify(h.devices.get('A')), aBefore); assert.equal(h.bindings.get(legacyId), 'A');
  assert.equal(h.registrations.length, 2); assert.equal(h.registrations[0].body.installation_id, legacyId);
  assert.notEqual(h.registrations[1].body.installation_id, legacyId); assert.equal(h.registrations[1].body.device_id, legacyId);
  assert.equal(h.saved.get('vex.vpn.legacy_key_owner.v1'), 'vex.vpn.account_registration.v1.42', 'permanent first owner marker must not be reassigned');
  assert.equal(h.generations(), 1); assert.equal(b.device.keyEpoch, 2);
  const restarted = harness('ios', h.saved); restarted.devices.set('B', h.devices.get('B'));
  const again = await restarted.prepare('B'); assert.equal(again.config, b.config);
  assert.equal(restarted.registrations.length, 0); assert.equal(restarted.generations(), 0);
});

test('pending legacy confirmation survives challenge, response and storage loss across restart', async () => {
  for (const interrupted of ['challenge', 'register', 'rotate', 'confirmation']) {
    const h = harness(); h.devices.set('B', [h.dto('B')]); h.interruptConfirmation(interrupted);
    const aBefore = JSON.stringify(h.devices.get('A'));
    await assert.rejects(h.prepare('B'), /подтвердить|response lost|storage lost/);
    const mapping = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.42'));
    assert.equal(mapping.legacyRegistrationPending, true, 'failed confirmation must remain durable');
    const journal = h.saved.get(`vex.vpn.account_keys.v1.${mapping.keyScope}.pending`);
    if (interrupted === 'rotate' || interrupted === 'confirmation') assert.ok(journal);
    const restarted = harness('ios', h.saved); restarted.devices.set('B', h.devices.get('B'));
    for (const [installation, owner] of h.bindings) restarted.bindings.set(installation, owner);
    const beforeGeneration = restarted.generations();
    const repaired = await restarted.prepare('B', { cachedDevice: { id: 'device-B', userId: 'B', status: 'active', protocol: 'amneziawg', externalDeviceId: legacyId, publicKey: legacyPair.publicKey, keyEpoch: 1 }, cachedConfig: 'stale-cache', knownVersion: 1 });
    assert.notEqual(repaired.device.publicKey, legacyPair.publicKey); assert.notEqual(repaired.config, 'stale-cache');
    if (journal) {
      assert.equal(repaired.device.publicKey, JSON.parse(journal).publicKey);
      assert.ok(repaired.config.includes(`PrivateKey = ${JSON.parse(journal).privateKey}`));
      assert.equal(restarted.generations(), beforeGeneration, 'confirmed durable private key must be recovered, not regenerated');
    }
    assert.equal(JSON.parse(h.saved.get('vex.vpn.account_registration.v1.42')).legacyRegistrationPending, false);
    assert.equal(h.saved.has(`vex.vpn.account_keys.v1.${mapping.keyScope}.pending`), false);
    assert.equal(JSON.stringify(h.devices.get('A')), aBefore); assert.equal(restarted.bindings.get(legacyId), 'A');
    assert.equal(restarted.devices.get('B').length, 1);
  }
});

test('indexed creation-header replay recovers pending private key after row deletion and lost rotation reply', async () => {
  const h = harness(); h.devices.set('B', [h.dto('B')]); h.removeLegacyBeforeRegister(); h.interruptConfirmation('rotate');
  const aBefore = JSON.stringify(h.devices.get('A'));
  await assert.rejects(h.prepare('B'), /rotation response lost/);
  const mapping = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.42'));
  const pending = JSON.parse(h.saved.get(`vex.vpn.account_keys.v1.${mapping.keyScope}.pending`));
  assert.equal(JSON.parse(h.saved.get(`vex.vpn.account_keys.v1.${mapping.keyScope}`)).publicKey, legacyPair.publicKey, 'active pair stays confirmed old until acknowledgement');
  const serverDevice = h.devices.get('B')[0]; assert.ok(serverDevice.fixture_creation_key);
  serverDevice.psk_epoch += 1; // An unrelated server-side PSK-only advance.
  const restarted = harness('ios', h.saved); restarted.devices.set('B', h.devices.get('B'));
  for (const [installation, owner] of h.bindings) restarted.bindings.set(installation, owner);
  const repaired = await restarted.prepare('B');
  assert.equal(repaired.device.id, serverDevice.id); assert.equal(repaired.device.publicKey, pending.publicKey);
  assert.ok(repaired.config.includes(`PrivateKey = ${pending.privateKey}`)); assert.equal(repaired.device.keyEpoch, 3);
  assert.equal(restarted.generations(), 0); assert.equal(restarted.requests.includes('/v1/vpn/rotate-key'), false);
  assert.equal(restarted.registrations[0].body.public_key, pending.publicKey); assert.equal(restarted.registrations[0].body.key_epoch, 3);
  assert.equal(JSON.stringify(h.devices.get('A')), aBefore); assert.equal(restarted.bindings.get(legacyId), 'A');
  assert.equal(JSON.parse(h.saved.get('vex.vpn.account_registration.v1.42')).legacyRegistrationPending, false);
});

test('cold restart and refreshed token reuse persisted account ID and key', async () => {
  const first = harness(); const b = await first.prepare('B');
  const second = harness('ios', first.saved); second.devices.set('B', first.devices.get('B'));
  const after = await second.prepare('B'); assert.equal(after.device.id, b.device.id); assert.equal(after.config, b.config);
  assert.equal(second.generations(), 0); assert.equal(second.registrations.length, 0);
});

test('historical same legacy external ID has independent keys and safe deleted-row re-registration', async () => {
  const h = harness(); h.devices.set('B', [h.dto('B', { public_key: key(8) })]);
  const a = await h.prepare('A'), b = await h.prepare('B');
  assert.notEqual(b.device.publicKey, a.device.publicKey); assert.equal(h.registrations.length, 3);
  const aBefore = JSON.stringify(h.devices.get('A')); h.devices.set('B', []);
  const repaired = await h.prepare('B');
  assert.equal(repaired.device.externalDeviceId, legacyId); assert.equal(h.registrations.length, 4);
  const bRequests = h.registrations.filter(request => request.owner === 'B');
  assert.equal(bRequests[0].body.installation_id, legacyId); assert.notEqual(bRequests[1].body.installation_id, legacyId);
  assert.equal(bRequests[1].body.device_id, legacyId); assert.notEqual(bRequests[0].idempotency, bRequests[1].idempotency);
  assert.equal(h.bindings.get(legacyId), 'A'); assert.equal(JSON.stringify(h.devices.get('A')), aBefore);
  assert.notEqual(repaired.config, a.config);
});

test('concurrent historical accounts sharing the global WG public key cannot adopt it twice', async () => {
  const h = harness(); h.devices.set('B', [h.dto('B')]);
  const [a, b] = await Promise.all([h.prepare('A'), h.prepare('B')]);
  assert.equal(a.device.id, 'device-A'); assert.equal(b.device.id, 'device-B');
  assert.notEqual(a.device.publicKey, b.device.publicKey); assert.notEqual(a.config, b.config);
  assert.equal(h.devices.get('A').length, 1); assert.equal(h.devices.get('B').length, 1); assert.equal(h.registrations.length, 3);
  assert.equal(h.bindings.get(legacyId), 'A');
  assert.ok(h.saved.has('vex.vpn.legacy_key_owner.v1'));
  const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A')); restarted.devices.set('B', h.devices.get('B'));
  const [againA, againB] = await Promise.all([restarted.prepare('A'), restarted.prepare('B')]);
  assert.equal(againA.device.publicKey, a.device.publicKey); assert.equal(againB.device.publicKey, b.device.publicKey); assert.equal(restarted.generations(), 0);
});

test('legacy key admission fails closed on marker persistence or corruption', async () => {
  const h = harness(); h.setMarkerFailure(true); await assert.rejects(h.prepare('A'), /persistence/);
  assert.equal(h.generations(), 0); assert.equal(h.registrations.length, 0);
  h.setMarkerFailure(false); assert.equal((await h.prepare('A')).device.publicKey, legacyPair.publicKey);
  const corrupt = harness(); corrupt.saved.set('vex.vpn.legacy_key_owner.v1', 'malformed');
  await assert.rejects(corrupt.prepare('A'), /владелец.*повреждён/); assert.equal(corrupt.generations(), 0);
  const empty = harness(); empty.saved.set('vex.vpn.legacy_key_owner.v1', '');
  await assert.rejects(empty.prepare('A'), /владелец.*повреждён/); assert.equal(empty.generations(), 0);
  assert.equal(empty.saved.get('vex.vpn.legacy_key_owner.v1'), '', 'corrupt permanent marker must not be reassigned');
});

test('account storage and idempotency namespaces distinguish separator-shaped user IDs', async () => {
  const h = harness(); const [a, b] = await Promise.all([h.prepare('a/b'), h.prepare('a_b')]);
  assert.notEqual(a.device.externalDeviceId, b.device.externalDeviceId); assert.notEqual(a.device.publicKey, b.device.publicKey);
  assert.equal([...h.saved.keys()].filter(value => value.startsWith('vex.vpn.account_registration')).length, 2);
  assert.notEqual(h.registrations[0].idempotency, h.registrations[1].idempotency);
});

test('staged PSK profile and explicit rotation use B scoped key without replacing A globals', async () => {
  const h = harness(); const b = await h.prepare('B');
  const staged = await h.api.fetchStagedDevicePSKProfile('B', { ...b, locationId: 'de' }, 'B', () => true);
  assert.equal(staged.profile.config, b.config);
  const rotated = await h.api.rotateManagedVpnKey('B', b.device.id, b.device.keyEpoch, () => true, 'B');
  assert.notEqual(rotated.publicKey, b.device.publicKey);
  assert.equal((await h.prepare('B')).device.publicKey, rotated.publicKey);
  assert.equal((await h.prepare('A')).device.publicKey, legacyPair.publicKey);
});

test('same-WG server PSK advances and staged next epoch preserve the account private key', async () => {
  const h = harness(); h.devices.set('A', [h.dto('A', { psk_epoch: 7 })]);
  const initial = await h.prepare('A'); assert.equal(initial.device.keyEpoch, 7); assert.equal(h.generations(), 0);
  const scoped = await h.scoped.getOrCreateVpnAccountIdentity({ userId: 'A', platform: 'ios', locationId: 'de', loadOwnedDevices: async () => [] });
  assert.equal(scoped.keyPair.keyEpoch, 7); assert.equal(scoped.keyPair.privateKey, legacyPair.privateKey);
  h.setStagedEpoch(8);
  const staged = await h.api.fetchStagedDevicePSKProfile('A', { ...initial, locationId: 'de' }, 'A', () => true);
  assert.equal(staged.profile.device.keyEpoch, 8); assert.notEqual(staged.profile.config, initial.config);
  assert.ok(staged.profile.config.includes(`PrivateKey = ${legacyPair.privateKey}`)); assert.ok(staged.profile.config.includes(`PresharedKey = ${key(28)}`));
  assert.equal(h.devices.get('A')[0].psk_epoch, 7, 'staging does not advance the active device epoch');
  h.devices.get('A')[0].psk_epoch = 8;
  const advanced = await h.prepare('A'); assert.equal(advanced.device.keyEpoch, 8); assert.equal(advanced.config, staged.profile.config);
  assert.equal(h.generations(), 0);
});

test('same-account rotation during suspended profile GET never returns an old private key', async () => {
  const h = harness(); const initial = await h.prepare('A');
  const suspended = gate(), reached = gate(); h.holdProfile(suspended, reached); h.allowLegacyReplacement();
  const pending = h.prepare('A'); const rejected = assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  await reached.promise;
  await h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A');
  suspended.resolve(); await rejected;
});

test('existing mapping and cached hints reject known foreign device ownership', async () => {
  const h = harness(); const b = await h.prepare('B');
  h.devices.set('B', [h.dto('A', { external_device_id: b.device.externalDeviceId })]);
  await assert.rejects(h.prepare('B'), /другому аккаунту/);
  await assert.rejects(h.prepare('B', { cachedDevice: { ...b.device, userId: 'A' }, cachedConfig: b.config, knownVersion: 1 }), /другому аккаунту/);
});

test('registration retries only exact legacy binding conflict; other errors keep mapping unchanged', async () => {
  for (const error of [new Error('network'), { status: 409, code: 'conflict', message: 'different_conflict' }, { status: 403, code: 'forbidden', message: 'device_rebind_required' }]) {
    const h = harness(); h.devices.set('B', [h.dto('B')]); await h.prepare('B'); h.devices.set('B', []);
    const failure = error instanceof Error ? error : new h.ApiRequestError(error.message, error); h.setRegisterError(failure);
    const before = [...h.saved.entries()].filter(([storageKey]) => storageKey.startsWith('vex.vpn.account_registration'));
    await assert.rejects(h.prepare('B'), received => received === failure);
    assert.equal(h.registrations.length, 3); assert.deepEqual([...h.saved.entries()].filter(([storageKey]) => storageKey.startsWith('vex.vpn.account_registration')), before);
  }
});

test('lookup/read/write failures allocate no server device and release account queue', async () => {
  for (const failure of ['Lookup', 'Read', 'Write']) {
    const h = harness(); h[`set${failure}Failure`](true);
    await assert.rejects(h.prepare('B'), /lookup unavailable|locked|persistence/);
    assert.equal(h.registrations.length, 0); assert.equal(h.devices.has('B'), false);
    h[`set${failure}Failure`](false); assert.ok((await h.prepare('B')).device.id);
  }
});

test('concurrent account preparations create one durable mapping and one registration', async () => {
  const h = harness(); const results = await Promise.all(Array.from({ length: 12 }, () => h.prepare('B')));
  assert.equal(new Set(results.map(result => result.device.id)).size, 1); assert.equal(h.generations(), 1); assert.equal(h.registrations.length, 1);
});

test('late account lookup after logout cannot generate, persist or register old account', async () => {
  const h = harness(), pendingLookup = gate(); let current = true; h.holdLookup(pendingLookup);
  const pending = h.prepare('B', { isCurrentSessionOperation: () => current });
  await new Promise(resolve => setImmediate(resolve)); current = false; pendingLookup.resolve();
  await assert.rejects(pending, error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  assert.equal(h.generations(), 0); assert.equal(h.registrations.length, 0); assert.equal(h.writes.filter(value => value.startsWith('vex.vpn.account_')).length, 0);
});

test('legacy selection rejects present mode/ownership/platform/owner inconsistencies', async () => {
  for (const fields of [{ provisioning_mode: 'manual' }, { client_key_ownership: 'backend' }, { platform: 'android' }]) {
    const h = harness(); h.devices.set('B', [h.dto('B', fields)]); const b = await h.prepare('B');
    assert.notEqual(b.device.externalDeviceId, legacyId); assert.notEqual(b.device.publicKey, legacyPair.publicKey);
  }
  const h = harness(); h.devices.set('B', [h.dto('A')]); await assert.rejects(h.prepare('B'), /другому аккаунту/); assert.equal(h.registrations.length, 0);
});

test('legacy records with absent optional fields retain migration compatibility', async () => {
  for (const fields of [{ platform: undefined }, { provisioning_mode: undefined }, { client_key_ownership: undefined }]) {
    const h = harness(); h.devices.set('A', [h.dto('A', fields)]); const a = await h.prepare('A');
    assert.equal(a.device.id, 'device-A'); assert.equal(a.device.publicKey, legacyPair.publicKey); assert.equal(h.generations(), 0);
  }
});

test('corrupt pair and ambiguous legacy list fail closed', async () => {
  const h = harness(); await h.prepare('B'); const pairKey = [...h.saved.keys()].find(value => value.startsWith('vex.vpn.account_keys.v1.'));
  h.saved.set(pairKey, '{}'); await assert.rejects(h.prepare('B'), /ключ VPN повреждён/); assert.equal(h.generations(), 1);
  const ambiguous = harness(); ambiguous.devices.set('B', [ambiguous.dto('B'), ambiguous.dto('B', { id: 'second' })]);
  await assert.rejects(ambiguous.prepare('B'), /неоднозначные/); assert.equal(ambiguous.registrations.length, 0);
  const empty = harness(); empty.saved.set('vex.vpn.account_registration.v1.42', '');
  await assert.rejects(empty.prepare('B'), /регистрация VPN повреждена/); assert.equal(empty.generations(), 0); assert.equal(empty.registrations.length, 0);
});

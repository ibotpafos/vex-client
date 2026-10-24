const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const { test } = require('node:test');
const { Buffer } = require('node:buffer');
const nodeCrypto = require('node:crypto');
const { p256 } = require('@noble/curves/nist.js');
const { hexToBytes } = require('@noble/curves/utils.js');

const sourceRoot = process.env.VEX_MOBILE_REGISTRATION_SOURCE_ROOT || path.resolve(__dirname, '..');
function load(file, names, stubs = {}) {
  const entryRoot = process.env.VEX_KEY_ADMISSION_ENTRY_ROOT;
  const root = entryRoot && ['src/vpn/profile.ts', 'src/vpn/useVpnProfileState.ts'].includes(file) ? entryRoot : sourceRoot;
  const source = stripTypeScriptTypes(fs.readFileSync(path.join(root, file), 'utf8'))
    .replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm, '').replace(/\bexport /g, '');
  return new Function(...Object.keys(stubs), source + `;return {${names}};`)(...Object.values(stubs));
}
const key = byte => Buffer.alloc(32, byte).toString('base64');
const legacyPair = { publicKey: key(1), privateKey: key(2), keyEpoch: 1 };
const legacyId = 'vexd_legacy-installation';
const gate = () => { let resolve; const promise = new Promise(ok => { resolve = ok; }); return { promise, resolve }; };

function harness(platform = 'ios', existingStore, nativeRouting = false) {
  const saved = existingStore || new Map([['vex.auth.device_id', legacyId]]);
  const devices = new Map(), bindings = new Map([[legacyId, 'A']]), registrations = [], writes = [], requests = [], rotations = [];
  let generations = 0, lookupFailure = false, writeFailure = false, readFailure = false, markerFailure = false, interruptedConfirmation, removeLegacyBeforeRegistration = false, registerError, holdLookup, holdProfile, profileReached, stagedEpoch, legacyReplacementAllowed = false;
  let globalPair = { ...legacyPair };
  let activeKeyWriteFailure = false;
  let rotationComplete;
  let rotationResponse = {};
  let registrationResponse = {};
  let registrationComplete;
  let beforeStoreWrite;
  let challengePurpose, challengePurposeSet = false;
  let challengeComplete;
  let reconciliationSupported = true;
  let challengeOverride = {};
  const store = {
    getItemAsync: async storageKey => { if (readFailure && storageKey.startsWith('vex.vpn.account_')) throw Error('locked'); return saved.get(storageKey) ?? null; },
    setItemAsync: async (storageKey, value) => { beforeStoreWrite?.(storageKey, value); writes.push(storageKey); if ((writeFailure && storageKey.startsWith('vex.vpn.account_')) || (activeKeyWriteFailure && storageKey.startsWith('vex.vpn.account_keys.') && !storageKey.endsWith('.pending')) || (markerFailure && storageKey === 'vex.vpn.legacy_key_owner.v1')) throw Error('persistence'); if (interruptedConfirmation === 'confirmation' && storageKey.startsWith('vex.vpn.account_registration') && JSON.parse(value).legacyRegistrationPending === false) throw Error('confirmation storage lost'); saved.set(storageKey, value); },
    deleteItemAsync: async storageKey => { saved.delete(storageKey); },
  };
  const app = load('src/native/appInfo.ts', 'getOrCreateDeviceId,getAppInfo,createInstallationUUID', { SecureStore: store, Application: {}, Platform: { OS: platform }, getOtaProvenance: () => ({}) });
  // Hermes has no browser SubtleCrypto. Exercise the real native signing path;
  // Node's separate WebCrypto verifier below still checks each request signature.
  const signer = load('src/native/deviceIdentity.ts', 'getOrCreateDeviceIdentity,deviceIdentitySignaturePayload', {
    SecureStore: store, Platform: { OS: platform }, globalThis: {}, p256, hexToBytes,
    Crypto: {
      CryptoDigestAlgorithm: { SHA256: 'SHA-256' },
      getRandomBytesAsync: async size => new Uint8Array(nodeCrypto.randomBytes(size)),
      digestStringAsync: async (_algorithm, payload) => nodeCrypto.createHash('sha256').update(payload, 'utf8').digest('hex'),
    },
  });
  const session = load('src/vpn/sessionOperation.ts', 'SessionOperationSupersededError');
  const native = { getOrCreateWireGuardKeyPair: async () => ({ ...globalPair }), generateWireGuardKeyPair: async options => { assert.equal(typeof options?.independentEpoch, 'boolean', 'account callers must choose their counter ownership explicitly'); return { publicKey: key(10 + ++generations), privateKey: key(90 + generations), keyEpoch: 2 }; }, replaceWireGuardKeyPair: async pair => { if (!legacyReplacementAllowed) throw Error('Global key must not be replaced'); globalPair = pair; } };
  const scoped = fs.existsSync(path.join(sourceRoot, 'src/native/vpnAccountIdentity.ts'))
    ? load('src/native/vpnAccountIdentity.ts', 'getOrCreateVpnAccountIdentity,withVpnAccountIdentity,saveVpnAccountKeyPair,pendingVpnAccountKeyPair,savePendingVpnAccountKeyPair,clearPendingVpnAccountKeyPair,rememberVpnAccountDevice,renewVpnAccountInstallation,confirmVpnAccountRegistration,vpnAccountRegistrationIdempotencyKey,validatedVpnAccountKeyPair', { SecureStore: store, ...app, ...native, ...session }) : {};
  const location = load('src/vpn/locationId.ts', 'requireVpnLocationId,comparableVpnLocationId');
  const selection = load('src/vpn/nativeDeviceSelection.ts', 'nativeVpnDeviceForClient', location);
  const errors = load('src/api/error.ts', 'ApiRequestError,requireRequestActive,isApiRequestCancelled,requestCancelledError');
  const { ApiRequestError } = errors;
  const cancellation = load('src/api/requestCancellation.ts', 'withRequestCancellation', errors);
  const ownerFor = token => token === 'refreshed-A' ? 'A' : token;
  const dto = (owner, extra = {}) => ({ id: `device-${owner}`, user_id: owner, status: 'active', protocol: 'amneziawg', platform, provisioning_mode: 'managed_native', client_key_ownership: 'client', external_device_id: legacyId, public_key: legacyPair.publicKey, psk_epoch: 1, ...extra });
  const profile = device => ({ device_id: device.id, assigned_ipv4: '10.0.0.2/32', server: 'fixture.example', port: 443, server_public_key: key(4), client_public_key: device.public_key, client_key_epoch: device.psk_epoch, preshared_key: key(device.psk_epoch + 20), version: 1 });
  devices.set('A', [dto('A')]);
  const jsonRequest = async (requestPath, options) => {
    requests.push(requestPath); const owner = ownerFor(options.accessToken);
    if (requestPath.startsWith('/v1/vpn/routing-policy?')) return {}; // Older API: no signed v2 policy.
    if (requestPath === '/v1/devices') { if (lookupFailure) throw Error('lookup unavailable'); if (holdLookup) await holdLookup.promise; return devices.get(owner) || []; }
    if (requestPath === '/v1/devices/identity-challenge') { if (interruptedConfirmation === 'challenge') throw Error('challenge unavailable'); challengeComplete?.(options.body); return { id: `challenge-${nodeCrypto.randomUUID()}`, nonce: `nonce-${owner}`, purpose: challengePurposeSet ? challengePurpose : options.body.purpose, ...challengeOverride }; }
    if (requestPath === '/v1/devices/register') {
      const body = options.body; registrations.push({ owner, body, idempotency: options.idempotencyKey, retryCount: options.retryCount });
      if (body.reconcile_device_id && !reconciliationSupported) {
        // A previous API ignores the new field, checks a creation replay first,
        // then rejects a reconcile-purpose challenge on a cache miss.
        const indexed = (devices.get(owner) || []).find(row => row.fixture_creation_key === options.idempotencyKey);
        if (indexed && indexed.public_key === body.public_key && indexed.psk_epoch === body.key_epoch) {
          indexed.app_version = body.app_version;
          return { device_registered: true, binding_status: 'active', trust_level: 'software_secure_store', device: { ...indexed } };
        }
        throw new ApiRequestError('device_identity_challenge_invalid', { status: 400, code: 'invalid_request' });
      }
      const publicKey = await crypto.subtle.importKey('jwk', JSON.parse(body.identity_public_key), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      const payload = signer.deviceIdentitySignaturePayload({ id: body.identity_challenge_id, nonce: `nonce-${owner}`, purpose: body.reconcile_device_id ? 'reconcile' : 'register' }, body.installation_id, body.identity_public_key, body.public_key);
      assert.equal(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, Buffer.from(body.identity_signature, 'base64url'), new TextEncoder().encode(payload)), true);
      if (registerError) throw registerError;
      if (body.reconcile_device_id) {
        const device = (devices.get(owner) || []).find(row => row.id === body.reconcile_device_id);
        if (!device || device.user_id !== owner || device.status !== 'active' || device.public_key !== body.public_key || device.psk_epoch !== body.key_epoch) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
        if (bindings.has(body.installation_id) && bindings.get(body.installation_id) !== owner) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
        registrationComplete?.(); if (interruptedConfirmation === 'register') throw Error('registration response lost');
        return { device_registered: true, binding_status: 'active', trust_level: 'software_secure_store', ...registrationResponse, device: { ...device, ...registrationResponse.device } };
      }
      if (removeLegacyBeforeRegistration && owner === 'B') { devices.set('B', []); removeLegacyBeforeRegistration = false; }
      // The real replay guard reads the current row indexed by its creation
      // header and rejects a stale request public key or authoritative epoch.
      const indexed = (devices.get(owner) || []).find(device => device.fixture_creation_key === options.idempotencyKey);
      if (indexed && (indexed.public_key !== body.public_key || indexed.psk_epoch !== body.key_epoch)) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
      if (bindings.has(body.installation_id) && bindings.get(body.installation_id) !== owner) throw new ApiRequestError('device_rebind_required', { status: 409, code: 'conflict' });
      const existing = (devices.get(owner) || []).find(device => device.status === 'active' && device.external_device_id === body.device_id);
      const device = existing || dto(owner, { id: `registered-${owner}-${registrations.length}`, external_device_id: body.device_id, public_key: body.public_key, psk_epoch: body.key_epoch, fixture_creation_key: options.idempotencyKey });
      if (!existing) devices.set(owner, [...(devices.get(owner) || []), device]);
      bindings.set(body.installation_id, owner); registrationComplete?.(); if (interruptedConfirmation === 'register') throw Error('registration response lost'); return { device_registered: true, binding_status: 'active', trust_level: 'software_secure_store', ...registrationResponse, device: { ...device, ...registrationResponse.device } };
    }
    if (requestPath === '/v1/vpn/rotate-key') {
      rotations.push({ owner, body: { ...options.body }, idempotencyKey: options.idempotencyKey, retryCount: options.retryCount });
      const device = (devices.get(owner) || []).find(item => item.id === options.body.device_id);
      if (options.body.key_epoch !== device.psk_epoch + 1) throw new ApiRequestError('key_epoch does not match next device epoch', { status: 409, code: 'conflict' });
      if (interruptedConfirmation === 'ordinary-rotate-before-commit') throw Error('rotation response lost before commit');
      if (interruptedConfirmation === 'ordinary-rotate-after-commit') {
        device.public_key = options.body.public_key; device.psk_epoch = options.body.key_epoch;
        throw Error('rotation response lost after commit');
      }
      if (interruptedConfirmation === 'rotate') {
        const pending = [...saved.entries()].find(([storageKey]) => storageKey.endsWith('.pending'));
        assert.ok(pending, 'repair private pair must be durable before rotation POST');
        assert.equal(JSON.parse(pending[1]).publicKey, options.body.public_key);
        device.public_key = options.body.public_key; device.psk_epoch = options.body.key_epoch; throw Error('rotation response lost');
      }
      device.public_key = options.body.public_key; device.psk_epoch = options.body.key_epoch;
      rotationComplete?.(); return { device: { ...device, ...rotationResponse } };
    }
    if (requestPath.startsWith('/v1/vpn/profile?')) {
      if (holdProfile) { profileReached.resolve(); await holdProfile.promise; }
      const query = new URLSearchParams(requestPath.split('?')[1]);
      const value = profile((devices.get(owner) || []).find(device => device.id === query.get('device_id')));
      return nativeRouting ? { ...value, allowed_ips: query.get('routing_mode') === 'full_tunnel' ? ['0.0.0.0/0', '::/0'] : ['0.0.0.0/1'] } : value;
    }
    if (requestPath.startsWith('/v1/vpn/psk-rotations/current?')) {
      const device = (devices.get(owner) || []).find(item => item.id === new URLSearchParams(requestPath.split('?')[1]).get('device_id'));
      return { activate: false, profile_version: 1, profile: profile(stagedEpoch === undefined ? device : { ...device, psk_epoch: stagedEpoch }), rotation_id: 'rotation', profile_digest: 'digest' };
    }
    throw Error(`Unexpected API route ${requestPath}`);
  };
  const api = load('src/api/vpn.ts', 'preparedTunnel,rotateManagedVpnKey,fetchStagedDevicePSKProfile,withCurrentVpnProfileKey,vpnProfileKeyIsCurrent,VpnProfileKeyChangedError', {
    ...load('src/vpn/profileNumbers.ts', 'isPositiveSafeInteger,isNonnegativeSafeInteger'),
    supportsNativeRoutingPolicy: () => nativeRouting, Platform: { OS: platform }, ...app, ...signer, ...native, ...scoped, ...location, ...selection, ...session,
    ...load('src/vpn/nativeRoutingPolicy.ts', 'nativeRoutingParameters,routingAuthorization'),
    ...load('src/api/nativeDeviceRegistration.ts', 'getOrCreateNativeDeviceRegistration'),
    ...load('src/vpn/keyEpochRecovery.ts', 'nextManagedKeyEpoch,isKeyEpochMismatchError', load('src/vpn/profileNumbers.ts', 'isNonnegativeSafeInteger')),
    ...load('src/vpn/amneziaConfig.ts', 'managedProfileAmneziaConfig'),
    ...load('src/vpn/profileRevalidation.ts', 'canRevalidateDevice', load('src/vpn/profileNumbers.ts', 'isNonnegativeSafeInteger')),
    me: async token => ({ id: ownerFor(token) }), clientVersionHeaders: async () => ({}), jsonRequest, ...errors, ...cancellation,
    defaultVpnRoutingMode: 'default', defaultVpnRoutingPolicyVersion: 'v1', resolvedVpnBypassRegion: () => '', withManagedProfileAWGCapability: query => query,
  });
  return { api, scoped, saved, devices, bindings, registrations, requests, writes, rotations, dto, generations: () => generations,
    setLookupFailure: value => { lookupFailure = value; }, setWriteFailure: value => { writeFailure = value; }, setReadFailure: value => { readFailure = value; }, setRegisterError: value => { registerError = value; }, holdLookup: value => { holdLookup = value; }, ApiRequestError,
    holdProfile: (value, reached) => { holdProfile = value; profileReached = reached; }, allowLegacyReplacement: () => { legacyReplacementAllowed = true; },
    setMarkerFailure: value => { markerFailure = value; },
    setActiveKeyWriteFailure: value => { activeKeyWriteFailure = value; },
    onRotationComplete: value => { rotationComplete = value; },
    setRotationResponse: value => { rotationResponse = value; },
    setRegistrationResponse: value => { registrationResponse = value; },
    onRegistrationComplete: value => { registrationComplete = value; },
    onStoreWrite: value => { beforeStoreWrite = value; },
    setChallengePurpose: value => { challengePurposeSet = true; challengePurpose = value; },
    onChallengeComplete: value => { challengeComplete = value; },
    setReconciliationSupported: value => { reconciliationSupported = value; },
    setChallengeOverride: value => { challengeOverride = value; },
    interruptConfirmation: value => { interruptedConfirmation = value; },
    removeLegacyBeforeRegister: () => { removeLegacyBeforeRegistration = true; },
    setStagedEpoch: value => { stagedEpoch = value; },
    prepare: (owner, options = {}) => api.preparedTunnel(owner, { platform, deviceName: platform, idempotencyPrefix: platform }, { userId: ownerFor(owner), locationId: 'de', isCurrentSessionOperation: () => true, ...options }),
  };
}

async function orphanedRotation(platform = 'ios', { owner = 'A', oldStatus = 'deleted', accepted = false, replacementEpoch = 4 } = {}) {
  const original = harness(platform); const initial = await original.prepare(owner);
  original.interruptConfirmation(accepted ? 'ordinary-rotate-after-commit' : 'ordinary-rotate-before-commit');
  await assert.rejects(original.api.rotateManagedVpnKey(owner, initial.device.id, initial.device.keyEpoch, () => true, owner));
  const mappingName = 'vex.vpn.account_registration.v1.' + Buffer.from(owner).toString('hex');
  const mapping = JSON.parse(original.saved.get(mappingName));
  const activeName = `vex.vpn.account_keys.v1.${mapping.keyScope}`; const pendingName = activeName + '.pending';
  const intent = original.saved.get(pendingName), active = original.saved.get(activeName), pending = JSON.parse(intent);
  const old = original.devices.get(owner).find(row => row.id === initial.device.id);
  const replacement = { ...old, id: 'replacement-' + owner, status: 'active', external_device_id: mapping.externalDeviceId,
    public_key: accepted ? pending.publicKey : JSON.parse(active).publicKey, psk_epoch: replacementEpoch };
  const rows = oldStatus === 'deleted' ? [replacement] : [{ ...old, status: oldStatus }, replacement];
  const restarted = harness(platform, original.saved); restarted.devices.set(owner, rows);
  return { original, restarted, owner, initial, mapping, mappingName, activeName, pendingName, active, intent, pending, replacement, rows };
}

for (const platform of ['android', 'ios']) {
  for (const owner of ['A', 'B']) test(`${platform}: deleted pending target recovers through its signed ${owner} registration`, async () => {
    const s = await orphanedRotation(platform, { owner }); const h = s.restarted;
    h.onRegistrationComplete(() => {
      assert.equal(h.saved.get(s.pendingName), s.intent, 'target must not transfer before its signed acknowledgement');
      assert.equal(h.saved.get(s.activeName), s.active);
    });
    h.onRotationComplete(() => {
      const transferred = JSON.parse(h.saved.get(s.pendingName));
      assert.equal(transferred.deviceId, s.replacement.id);
      assert.equal(transferred.publicKey, s.pending.publicKey);
      assert.equal(h.saved.get(s.activeName), s.active, 'rotation response must precede active-key promotion');
    });
    const recovered = await h.prepare(owner);
    assert.equal(h.registrations.length, 1); assert.equal(h.registrations[0].retryCount, 0);
    assert.equal(h.registrations[0].body.installation_id, s.mapping.installationId);
    assert.equal(h.rotations.length, 1); assert.equal(h.rotations[0].body.device_id, s.replacement.id);
    assert.equal(h.rotations[0].body.public_key, s.pending.publicKey); assert.equal(h.rotations[0].body.key_epoch, 5);
    assert.equal(h.generations(), 0); assert.equal(h.saved.has(s.pendingName), false);
    assert.equal(JSON.parse(h.saved.get(s.mappingName)).confirmedDeviceId, s.replacement.id);
    assert.ok(recovered.config.includes(`PrivateKey = ${s.pending.privateKey}`));
  });

  test(`${platform}: revoked source can recover while the revoked row stays untouched`, async () => {
    const s = await orphanedRotation(platform, { oldStatus: 'revoked' }); const old = JSON.stringify(s.rows[0]);
    const recovered = await s.restarted.prepare('A');
    assert.equal(recovered.device.id, s.replacement.id); assert.equal(JSON.stringify(s.rows[0]), old);
    assert.equal(s.restarted.rotations.length, 1); assert.equal(s.restarted.generations(), 0);
  });

  test(`${platform}: replacement already carrying the pending key is confirmed without another rotation`, async () => {
    const s = await orphanedRotation(platform, { accepted: true, replacementEpoch: 8 }); const h = s.restarted;
    const recovered = await h.prepare('A');
    assert.equal(h.registrations.length, 1); assert.equal(h.registrations[0].body.public_key, s.pending.publicKey);
    assert.equal(h.registrations[0].body.key_epoch, 8); assert.equal(h.rotations.length, 0); assert.equal(h.generations(), 0);
    assert.equal(recovered.device.keyEpoch, 8); assert.ok(recovered.config.includes(`PrivateKey = ${s.pending.privateKey}`));
    assert.equal(h.saved.has(s.pendingName), false);
  });

  for (const failure of ['register', 'ordinary-rotate-before-commit', 'ordinary-rotate-after-commit']) test(`${platform}: interrupted replacement ${failure} resumes its original key`, async () => {
    const s = await orphanedRotation(platform); const h = s.restarted;
    h.interruptConfirmation(failure);
    await assert.rejects(h.prepare('A'));
    assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.generations(), 0);
    const durable = JSON.parse(h.saved.get(s.pendingName));
    assert.equal(durable.privateKey, s.pending.privateKey);
    assert.equal(durable.deviceId, failure === 'register' ? s.pending.deviceId : s.replacement.id);
    const resumed = harness(platform, h.saved); resumed.devices.set('A', h.devices.get('A'));
    const recovered = await resumed.prepare('A');
    assert.equal(resumed.generations(), 0); assert.ok(recovered.config.includes(`PrivateKey = ${s.pending.privateKey}`));
    assert.equal(resumed.rotations.length, failure === 'ordinary-rotate-after-commit' ? 0 : 1);
    assert.equal(resumed.registrations.length, failure === 'register' ? 1 : 0);
  });

  test(`${platform}: transfer persistence failure cannot dispatch rotation or promote the active key`, async () => {
    const s = await orphanedRotation(platform); const h = s.restarted;
    h.setWriteFailure(true); await assert.rejects(h.prepare('A'), /persistence/);
    assert.equal(h.registrations.length, 1); assert.equal(h.rotations.length, 0);
    assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
  });

  test(`${platform}: replacement acknowledgement cannot outlive the current session`, async () => {
    const s = await orphanedRotation(platform); const h = s.restarted; let current = true;
    h.onRegistrationComplete(() => { current = false; });
    await assert.rejects(h.prepare('A', { isCurrentSessionOperation: () => current }), error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    assert.equal(h.rotations.length, 0); assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
  });
}

for (const response of [
  { device_registered: false }, { binding_status: 'legacy' }, { trust_level: 'legacy_unverified' },
  { device: { id: 'another-device' } }, { device: { user_id: 'B' } }, { device: { public_key: key(44) } },
  { device: { psk_epoch: 0 } }, { device: { psk_epoch: 3 } }, { device: { platform: 'android' } },
  { device: { status: 'revoked' } }, { device: { client_key_ownership: 'backend' } },
  { device: { provisioning_mode: 'legacy' } }, { device: { client_key_ownership: undefined } },
]) test(`replacement recovery refuses a mismatched signed acknowledgement ${JSON.stringify(response)}`, async () => {
  const s = await orphanedRotation(); const h = s.restarted; h.setRegistrationResponse(response);
  await assert.rejects(h.prepare('A'));
  assert.equal(h.rotations.length, 0); assert.equal(h.generations(), 0);
  assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
});

for (const change of ['foreign-owner', 'missing-owner', 'newer-key', 'active-source', 'unrecorded-source', 'challenge']) test(`replacement recovery cannot bypass ${change}`, async () => {
  const s = await orphanedRotation('ios', { oldStatus: change === 'active-source' ? 'active' : 'deleted' }); const h = s.restarted;
  if (change === 'foreign-owner') s.replacement.user_id = 'B';
  if (change === 'missing-owner') delete s.replacement.user_id;
  if (change === 'newer-key') s.replacement.public_key = key(44);
  if (change === 'unrecorded-source') {
    const mapping = JSON.parse(h.saved.get(s.mappingName)); delete mapping.confirmedDeviceId; delete mapping.legacyOwnedDeviceId;
    h.saved.set(s.mappingName, JSON.stringify(mapping));
  }
  if (change === 'challenge') h.interruptConfirmation('challenge');
  await assert.rejects(h.api.rotateManagedVpnKey('A', s.replacement.id, s.replacement.psk_epoch, () => true, 'A'));
  assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
  assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
});

for (const purpose of ['register', '', undefined, 'replace']) test(`older server purpose ${String(purpose)} cannot authorize a reconciliation POST`, async () => {
  const s = await orphanedRotation(); const h = s.restarted;
  h.setChallengePurpose(purpose);
  await assert.rejects(h.prepare('A'));
  assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
  assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
});

test('a candidate disappearing after its challenge cannot create another device', async () => {
  const s = await orphanedRotation(); const h = s.restarted;
  h.onChallengeComplete(body => { if (body.purpose === 'reconcile') h.devices.set('A', []); });
  await assert.rejects(h.prepare('A'));
  assert.deepEqual(h.devices.get('A'), []); assert.equal(h.rotations.length, 0);
  assert.equal(h.saved.get(s.pendingName), s.intent); assert.equal(h.saved.get(s.activeName), s.active);
  assert.equal(h.registrations[0].body.reconcile_device_id, s.replacement.id);
});

test('a new challenge followed by an old registration node cannot replay a creation write', async () => {
  const s = await orphanedRotation(); const h = s.restarted;
  s.replacement.fixture_creation_key = h.scoped.vpnAccountRegistrationIdempotencyKey('A', s.mapping.installationId, 'de');
  s.replacement.app_version = 'prior-version';
  const before = JSON.stringify(h.devices.get('A'));
  h.setReconciliationSupported(false);
  await assert.rejects(h.prepare('A'), /device_identity_challenge_invalid/);
  assert.equal(JSON.stringify(h.devices.get('A')), before); assert.equal(h.rotations.length, 0);
  assert.equal(h.saved.get(s.pendingName), s.intent); assert.equal(h.saved.get(s.activeName), s.active);
  assert.match(h.registrations[0].idempotency, /^native-reconcile-challenge-/);
});

for (const id of [undefined, '', '../invalid', 'x'.repeat(129)]) test(`malformed reconcile challenge ID ${String(id)} cannot reach registration`, async () => {
  const s = await orphanedRotation(); const h = s.restarted; h.setChallengeOverride({ id });
  await assert.rejects(h.prepare('A'));
  assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
  assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
});

for (const id of ['', undefined, null, '   ', 14, 'x'.repeat(161)]) test(`malformed replacement ID ${String(id)} cannot turn reconciliation into registration`, async () => {
  const s = await orphanedRotation(); const h = s.restarted; s.replacement.id = id;
  await assert.rejects(h.prepare('A'));
  assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
  assert.equal(h.requests.includes('/v1/devices/identity-challenge'), false);
  assert.equal(h.generations(), 0); assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
});

test('a malformed replacement cannot trigger legacy registration before recovery', async () => {
  const s = await orphanedRotation(); const h = s.restarted; s.replacement.id = '';
  const mapping = JSON.parse(h.saved.get(s.mappingName)); mapping.legacyRegistrationPending = true;
  h.saved.set(s.mappingName, JSON.stringify(mapping));
  await assert.rejects(h.prepare('A'));
  assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
  assert.equal(h.requests.includes('/v1/devices/identity-challenge'), false);
  assert.equal(h.saved.get(s.pendingName), s.intent); assert.equal(h.saved.get(s.activeName), s.active);
});

test('a legacy recorded source remains recoverable without the new optional mapping field', async () => {
  const s = await orphanedRotation(); const h = s.restarted;
  const mapping = JSON.parse(h.saved.get(s.mappingName)); assert.equal(mapping.legacyOwnedDeviceId, s.pending.deviceId);
  delete mapping.confirmedDeviceId; h.saved.set(s.mappingName, JSON.stringify(mapping));
  const recovered = await h.prepare('A');
  assert.equal(recovered.device.id, s.replacement.id); assert.equal(h.rotations.length, 1); assert.equal(h.generations(), 0);
});

test('a crash between transferred journal and mapping pointer is recoverable without registration replay', async () => {
  const s = await orphanedRotation(); const h = s.restarted;
  h.onStoreWrite((name, raw) => {
    if (name === s.mappingName && JSON.parse(raw).confirmedDeviceId === s.replacement.id) throw Error('pointer storage unavailable');
  });
  await assert.rejects(h.prepare('A'), /pointer storage/);
  assert.equal(JSON.parse(h.saved.get(s.pendingName)).deviceId, s.replacement.id);
  assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.rotations.length, 0);
  const resumed = harness('ios', h.saved); resumed.devices.set('A', h.devices.get('A'));
  const recovered = await resumed.prepare('A');
  assert.equal(resumed.registrations.length, 0); assert.equal(resumed.rotations.length, 1);
  assert.equal(resumed.generations(), 0); assert.ok(recovered.config.includes(`PrivateKey = ${s.pending.privateKey}`));
});

test('supersession during source pointer persistence cannot create a rotation intent or send it', async () => {
  const h = harness(); const initial = await h.prepare('A'); let current = true;
  h.onStoreWrite((name, raw) => {
    if (name.startsWith('vex.vpn.account_registration.') && JSON.parse(raw).confirmedDeviceId) current = false;
  });
  await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => current, 'A'), error => error.code === 'SESSION_OPERATION_SUPERSEDED');
  assert.equal(h.rotations.length, 0); assert.equal([...h.saved.keys()].some(name => name.endsWith('.pending')), false);
});

test('a malformed optional source pointer is rejected before registration or rotation', async () => {
  for (const value of ['', 42, 'other device', 'x'.repeat(161)]) {
    const s = await orphanedRotation(); const h = s.restarted;
    const mapping = JSON.parse(h.saved.get(s.mappingName)); mapping.confirmedDeviceId = value;
    h.saved.set(s.mappingName, JSON.stringify(mapping));
    await assert.rejects(h.prepare('A'), /регистрация.*повреждена/);
    assert.equal(h.registrations.length, 0); assert.equal(h.rotations.length, 0);
    assert.equal(h.saved.get(s.activeName), s.active); assert.equal(h.saved.get(s.pendingName), s.intent);
  }
});

for (const platform of ['android', 'ios']) test(`${platform}: native routing uses a complete transport on a v1 server and cannot reuse a split cache`, async () => {
  const h = harness(platform, undefined, true);
  const first = await h.prepare('A', { routingMode: 'all_except_ru', bypassRegion: 'ru' });
  const queries = () => h.requests.filter(path => path.startsWith('/v1/vpn/profile?')).map(path => new URLSearchParams(path.split('?')[1]));
  assert.equal(queries().at(-1).get('routing_mode'), 'full_tunnel');
  assert.equal(queries().at(-1).get('routing_policy_version'), '2');
  assert.equal(queries().at(-1).has('bypass_region'), false);
  assert.match(first.config, /AllowedIPs = 0\.0\.0\.0\/0, ::\/0/);
  assert.equal(first.routingMode, 'all_except_ru');
  assert.equal(JSON.parse(first.routingParameters).authorization, undefined);
  const next = await h.prepare('A', {
    routingMode: 'all_except_ru', bypassRegion: 'ru',
    cachedDevice: first.device, cachedConfig: 'legacy split cache', knownVersion: 1,
  });
  assert.equal(queries().at(-1).has('known_version'), false);
  assert.notEqual(next.config, 'legacy split cache');
  assert.match(next.config, /AllowedIPs = 0\.0\.0\.0\/0, ::\/0/);
});

for (const platform of ['android', 'ios']) test(`${platform}: A logout → B login → A keeps distinct logical identities and one A device`, async () => {
  const h = harness(platform);
  const a = await h.prepare('A'), b = await h.prepare('B'), again = await h.prepare('refreshed-A');
  assert.equal(a.device.id, 'device-A'); assert.equal(again.device.id, a.device.id);
  assert.notEqual(b.device.externalDeviceId, legacyId); assert.notEqual(b.device.publicKey, a.device.publicKey);
  assert.equal(h.devices.get('A').length, 1); assert.equal(h.devices.get('B').length, 1); assert.equal(h.registrations.length, 2);
  assert.ok(again.config.includes(`PrivateKey = ${legacyPair.privateKey}`));
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


for (const platform of ['android', 'ios']) {
  for (const fault of ['ordinary-rotate-before-commit', 'ordinary-rotate-after-commit', 'active-key-persistence']) {
    test(`${platform}: ordinary rotation retains its prepared private key across ${fault}`, async () => {
      const h = harness(platform); const initial = await h.prepare('A');
      const mapping = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41'));
      const activeKey = `vex.vpn.account_keys.v1.${mapping.keyScope}`;
      const old = h.saved.get(activeKey);
      if (fault === 'active-key-persistence') h.setActiveKeyWriteFailure(true);
      else h.interruptConfirmation(fault);
      await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'), /response lost|persistence/);
      const pendingRaw = h.saved.get(activeKey + '.pending');
      assert.ok(pendingRaw, 'prepared private material must be durable before the mutation');
      const pending = JSON.parse(pendingRaw);
      assert.equal(pending.deviceId, initial.device.id, 'the intent belongs to one device');
      assert.equal(h.saved.get(activeKey), old, 'the confirmed pair remains active until acknowledgement is durable');
      const after = h.devices.get('A')[0];
      const restarted = harness(platform, h.saved); restarted.devices.set('A', h.devices.get('A'));
      for (const [installation, owner] of h.bindings) restarted.bindings.set(installation, owner);
      const repaired = await restarted.prepare('A');
      assert.equal(repaired.device.id, initial.device.id);
      assert.equal(repaired.device.publicKey, pending.publicKey);
      assert.ok(repaired.config.includes(`PrivateKey = ${pending.privateKey}`));
      assert.equal(restarted.generations(), 0, 'recovery must reuse the durable material');
      assert.equal(restarted.requests.filter(route => route === '/v1/vpn/rotate-key').length, fault === 'ordinary-rotate-before-commit' ? 1 : 0);
      assert.equal(after.public_key, pending.publicKey);
      assert.equal(h.saved.has(activeKey + '.pending'), false);
    });
  }
}


for (const platform of ['android', 'ios']) {
  test(`${platform}: uncommitted rotation resumes the exact saved request without new material`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    const request = h.rotations[0]; assert.equal(request.retryCount, 0);
    assert.equal(Object.hasOwn(request.body, 'private_key'), false);
    const restarted = harness(platform, h.saved); restarted.devices.set('A', h.devices.get('A'));
    await restarted.prepare('A');
    assert.equal(restarted.generations(), 0); assert.deepEqual(restarted.rotations, [request]);
  });

  test(`${platform}: cancellation after server rotation retains a recoverable intent`, async () => {
    const h = harness(platform); const initial = await h.prepare('A'); let current = true;
    h.onRotationComplete(() => { current = false; });
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => current, 'A'), error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    const restarted = harness(platform, h.saved); restarted.devices.set('A', h.devices.get('A'));
    const recovered = await restarted.prepare('A');
    assert.equal(recovered.device.publicKey, h.rotations[0].body.public_key);
    assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
  });

  test(`${platform}: a later server PSK epoch confirms the same pending private material`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-after-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    h.devices.get('A')[0].psk_epoch += 1;
    const restarted = harness(platform, h.saved); restarted.devices.set('A', h.devices.get('A'));
    const recovered = await restarted.prepare('A');
    assert.equal(recovered.device.keyEpoch, initial.device.keyEpoch + 2);
    assert.equal(recovered.device.publicKey, h.rotations[0].body.public_key);
    assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
  });

  test(`${platform}: no rotation is posted when its private journal cannot be saved`, async () => {
    const h = harness(platform); const initial = await h.prepare('A'); const before = JSON.stringify(h.devices.get('A'));
    h.setWriteFailure(true);
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'), /persistence/);
    assert.equal(h.rotations.length, 0); assert.equal(JSON.stringify(h.devices.get('A')), before);
  });

  test(`${platform}: stale explicit rotation does not create a second key after completion`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    await h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A');
    const generations = h.generations();
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'), error => error.code === 'SESSION_OPERATION_SUPERSEDED');
    assert.equal(h.rotations.length, 1); assert.equal(h.generations(), generations);
  });
}

for (const change of ['target', 'newer-key', 'foreign-owner', 'malformed-target']) {
  test(`pending rotation cannot overwrite ${change}`, async () => {
    const h = harness(); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    const mapping = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41'));
    const name = `vex.vpn.account_keys.v1.${mapping.keyScope}.pending`;
    const pending = JSON.parse(h.saved.get(name));
    if (change === 'target') pending.deviceId = 'different-device';
    if (change === 'malformed-target') pending.deviceId = 42;
    h.saved.set(name, JSON.stringify(pending));
    if (change === 'newer-key') Object.assign(h.devices.get('A')[0], { public_key: key(44), psk_epoch: 9 });
    if (change === 'foreign-owner') h.devices.get('A')[0].user_id = 'B';
    const snapshot = JSON.stringify(h.devices.get('A'));
    const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
    await assert.rejects(restarted.prepare('A'));
    assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
    assert.equal(JSON.stringify(h.devices.get('A')), snapshot); assert.equal(h.saved.get(name), JSON.stringify(pending));
  });
}

for (const response of [{ id: 'other-device' }, { public_key: key(44) }, { psk_epoch: 50 }]) {
  test(`a mismatched rotation acknowledgement preserves its durable intent ${Object.keys(response)[0]}`, async () => {
    const h = harness(); const initial = await h.prepare('A'); h.setRotationResponse(response);
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'), /не подтвердил/);
    const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
    const repaired = await restarted.prepare('A');
    assert.equal(repaired.device.publicKey, h.rotations[0].body.public_key);
    assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
  });
}


for (const platform of ['android', 'ios']) {
  test(`${platform}: direct retry confirms a committed pending rotation without another POST`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-after-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    h.interruptConfirmation(undefined); const generations = h.generations();
    const recovered = await h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A');
    assert.equal(recovered.publicKey, h.rotations[0].body.public_key);
    assert.equal(h.rotations.length, 1); assert.equal(h.generations(), generations);
  });

  test(`${platform}: cached hints cannot bypass an uncommitted durable rotation`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    h.interruptConfirmation(undefined); const generations = h.generations(); const offset = h.requests.length;
    const recovered = await h.prepare('A', { cachedDevice: initial.device, cachedConfig: initial.config, knownVersion: 1 });
    const work = h.requests.slice(offset);
    assert.equal(work[0], '/v1/devices', 'reconcile owned state before issuing another profile');
    assert.ok(work.indexOf('/v1/vpn/rotate-key') < work.findIndex(route => route.startsWith('/v1/vpn/profile?')));
    assert.notEqual(recovered.config, initial.config); assert.equal(recovered.device.publicKey, h.rotations[0].body.public_key);
    assert.equal(h.generations(), generations); assert.deepEqual(h.rotations[1], h.rotations[0]);
  });

  test(`${platform}: PSK-only advancement before commit reuses the pending key at the current counter`, async () => {
    const h = harness(platform); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    h.devices.get('A')[0].psk_epoch += 2;
    const restarted = harness(platform, h.saved); restarted.devices.set('A', h.devices.get('A'));
    const repaired = await restarted.prepare('A');
    assert.equal(repaired.device.keyEpoch, initial.device.keyEpoch + 3);
    assert.equal(repaired.device.publicKey, h.rotations[0].body.public_key);
    assert.equal(restarted.rotations.length, 1); assert.equal(restarted.generations(), 0);
    assert.notEqual(restarted.rotations[0].idempotencyKey, h.rotations[0].idempotencyKey);
  });
}

test('legacy pending pairs remain readable and new device targets round-trip in the same journal', async () => {
  const h = harness(); const pair = { publicKey: key(44), privateKey: key(45), keyEpoch: 3 };
  await h.scoped.savePendingVpnAccountKeyPair('fixture-scope', pair);
  assert.deepEqual(await h.scoped.pendingVpnAccountKeyPair('fixture-scope'), pair);
  const targeted = { ...pair, deviceId: 'fixture-device' };
  await h.scoped.savePendingVpnAccountKeyPair('fixture-scope', targeted);
  assert.deepEqual(await h.scoped.pendingVpnAccountKeyPair('fixture-scope'), targeted);
  await assert.rejects(h.scoped.savePendingVpnAccountKeyPair('fixture-scope', { ...pair, deviceId: ' ' }), /повреждено/);
  assert.deepEqual(await h.scoped.pendingVpnAccountKeyPair('fixture-scope'), targeted);
});


test('another account completes its own rotation without consuming an unresolved private intent', async () => {
  const h = harness(); const a = await h.prepare('A'); const b = await h.prepare('B');
  h.interruptConfirmation('ordinary-rotate-after-commit');
  await assert.rejects(h.api.rotateManagedVpnKey('A', a.device.id, a.device.keyEpoch, () => true, 'A'));
  const aScope = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41')).keyScope;
  const aIntentName = `vex.vpn.account_keys.v1.${aScope}.pending`;
  const aIntent = h.saved.get(aIntentName);
  h.interruptConfirmation(undefined);
  const rotatedB = await h.api.rotateManagedVpnKey('B', b.device.id, b.device.keyEpoch, () => true, 'B');
  assert.notEqual(rotatedB.publicKey, JSON.parse(aIntent).publicKey);
  assert.equal(h.saved.get(aIntentName), aIntent);
  const bState = JSON.stringify(h.devices.get('B'));
  const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A')); restarted.devices.set('B', h.devices.get('B'));
  const repairedA = await restarted.prepare('A');
  assert.equal(repairedA.device.publicKey, JSON.parse(aIntent).publicKey);
  assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
  assert.equal(JSON.stringify(h.devices.get('B')), bState);
});


for (const format of ['bound', 'target-only']) for (const server of ['newer-local-key', 'pending-key']) {
  test(`a stale ${format} pending intent cannot replace a newer confirmed local owner while server has ${server}`, async () => {
    const h = harness(); const initial = await h.prepare('A');
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    const scope = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41')).keyScope;
    const activeName = `vex.vpn.account_keys.v1.${scope}`;
    const pendingName = activeName + '.pending'; const pending = JSON.parse(h.saved.get(pendingName));
    if (format === 'target-only') { delete pending.basePublicKey; delete pending.ownerPublicKey; h.saved.set(pendingName, JSON.stringify(pending)); }
    const intent = h.saved.get(pendingName);
    // A prior app version or another confirmed writer completed a newer key
    // while the earlier durable intent remained on disk.
    const newer = { publicKey: key(46), privateKey: key(47), keyEpoch: 5 };
    h.saved.set(activeName, JSON.stringify(newer));
    Object.assign(h.devices.get('A')[0], { public_key: server === 'newer-local-key' ? newer.publicKey : pending.publicKey, psk_epoch: server === 'newer-local-key' ? 5 : pending.keyEpoch });
    const snapshot = JSON.stringify(h.devices.get('A'));
    const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
    await assert.rejects(restarted.prepare('A'));
    assert.equal(restarted.rotations.length, 0); assert.equal(restarted.generations(), 0);
    assert.equal(h.saved.get(activeName), JSON.stringify(newer)); assert.equal(h.saved.get(pendingName), intent);
    assert.equal(JSON.stringify(h.devices.get('A')), snapshot);
  });
}


for (const outcome of ['ordinary-rotate-before-commit', 'ordinary-rotate-after-commit']) {
  test(`an older target-only journal retains recovery for ${outcome}`, async () => {
    const h = harness(); const initial = await h.prepare('A'); h.interruptConfirmation(outcome);
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    const scope = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41')).keyScope;
    const name = `vex.vpn.account_keys.v1.${scope}.pending`; const pending = JSON.parse(h.saved.get(name));
    delete pending.basePublicKey; delete pending.ownerPublicKey; h.saved.set(name, JSON.stringify(pending));
    const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
    const recovered = await restarted.prepare('A');
    assert.equal(recovered.device.publicKey, pending.publicKey); assert.equal(restarted.generations(), 0);
    assert.equal(restarted.rotations.length, outcome === 'ordinary-rotate-before-commit' ? 1 : 0);
    assert.ok(recovered.config.includes(`PrivateKey = ${pending.privateKey}`));
  });
}

test('an uncommitted placeholder replacement resumes against its saved server and local base', async () => {
  const h = harness(); const initial = await h.prepare('A');
  Object.assign(h.devices.get('A')[0], { public_key: key(48), psk_epoch: 5 });
  h.interruptConfirmation('ordinary-rotate-before-commit');
  await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, 5, () => true, 'A'));
  const scope = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41')).keyScope;
  const pending = JSON.parse(h.saved.get(`vex.vpn.account_keys.v1.${scope}.pending`));
  assert.equal(pending.basePublicKey, key(48)); assert.equal(pending.ownerPublicKey, initial.device.publicKey);
  const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
  const repaired = await restarted.prepare('A');
  assert.equal(repaired.device.publicKey, pending.publicKey); assert.equal(repaired.device.keyEpoch, 6);
  assert.equal(restarted.generations(), 0); assert.equal(restarted.rotations.length, 1);
});


for (const advanced of [false, true]) {
  test(`an omitted server base key ${advanced ? 'cannot authorize a counter rebase' : 'retains exact-counter recovery'}`, async () => {
    const h = harness(); const initial = await h.prepare('A');
    h.devices.get('A')[0].public_key = undefined;
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', initial.device.id, initial.device.keyEpoch, () => true, 'A'));
    const scope = JSON.parse(h.saved.get('vex.vpn.account_registration.v1.41')).keyScope;
    const name = `vex.vpn.account_keys.v1.${scope}.pending`; const intent = h.saved.get(name);
    assert.equal(JSON.parse(intent).basePublicKey, '');
    if (advanced) h.devices.get('A')[0].psk_epoch += 2;
    const snapshot = JSON.stringify(h.devices.get('A'));
    const restarted = harness('ios', h.saved); restarted.devices.set('A', h.devices.get('A'));
    if (advanced) {
      await assert.rejects(restarted.prepare('A'));
      assert.equal(restarted.rotations.length, 0); assert.equal(h.saved.get(name), intent);
      assert.equal(JSON.stringify(h.devices.get('A')), snapshot);
    } else {
      const recovered = await restarted.prepare('A');
      assert.equal(recovered.device.publicKey, JSON.parse(intent).publicKey);
      assert.equal(restarted.rotations.length, 1); assert.equal(h.saved.has(name), false);
    }
    assert.equal(restarted.generations(), 0);
  });
}


// Exercise the production cache/hook/native-dispatch entry points with the
// same durable account owner and signed API fixture used above.
const paidAccess = { active: true, vpnAccess: true };
function profileOwners(h, hotProfile) {
  const location = load('src/vpn/locationId.ts', 'requireVpnLocationId,comparableVpnLocationId');
  const core = load('src/vpn/hotProfileCacheCore.ts', 'runtimeProfileKey,vpnProfileCacheIsCurrent,profileFromHotRecord,withLastSuccessfulEndpoint', location);
  const consistency = load('src/vpn/profileConsistency.ts', 'vpnProfileAddressMatchesDevice,vpnProfileInterfaceIpv4');
  const session = load('src/vpn/sessionOperation.ts', 'SessionOperationSupersededError');
  const errors = load('src/api/error.ts', 'requireRequestActive,requestCancelledError,isApiRequestCancelled');
  const cancellation = load('src/api/requestCancellation.ts', 'withRequestCancellation', errors);
  const api = { ...h.api, entitlement: async () => paidAccess, hasPaidEntitlement: value => !!value?.vpnAccess };
  const revalidation = load('src/vpn/profileRevalidation.ts', 'profileRevalidationOptions', {
    ...consistency, ...load('src/vpn/profileNumbers.ts', 'isPositiveSafeInteger,isNonnegativeSafeInteger'),
  });
  const record = () => hotProfile && { profile: hotProfile, savedAtMs: Date.now() };
  const profiles = load('src/vpn/profile.ts', 'resolveVpnProfile,resetVpnProfileCache,rotateVpnProfileKey', {
    ...api, ...core, ...consistency, ...session, ...errors, ...cancellation, ...location, ...revalidation,
    ...load('src/vpn/profileNumbers.ts', 'isPositiveSafeInteger'),
    defaultVpnRoutingMode: 'default', defaultVpnBypassRegion: '', defaultVpnRoutingPolicyVersion: 'v1',
    loadHotVpnProfile: async () => record(), runProfileRequest: work => work(undefined),
  });
  return { api, profiles, core, consistency, session, record };
}
function profileState(h, platform, cached, hot) {
  const owners = profileOwners(h, hot);
  const queryClient = {
    getQueryData: () => cached, setQueryData: () => {}, removeQueries: () => {},
    fetchQuery: ({ queryFn }) => queryFn(), invalidateQueries: async () => {},
  };
  const react = { useCallback: fn => fn, useEffect: () => {}, useMemo: fn => fn(), useRef: value => ({ current: value }) };
  const module = load('src/vpn/useVpnProfileState.ts', 'useVpnProfileState', {
    ...react, useQueryClient: () => queryClient, isCancelledError: () => false,
    useOwnedState: (_owner, _isCurrent, value) => [value, () => {}],
    Platform: { OS: platform }, errorMessage: error => error.message,
    ...owners.api, ...owners.profiles, ...owners.session,
    isApiRequestCancelled: () => false, ProfileRequestSupersededError: class extends Error {},
    clearHotVpnProfiles: async () => {}, hydrateHotVpnProfilesToQueryCache: async () => [],
    loadHotVpnProfileResult: async () => ({ record: owners.record() }),
    profileFromHotRecord: owners.core.profileFromHotRecord, saveHotVpnProfile: async () => {},
    connectableLocalProfile: load('src/vpn/connectFlow.ts', 'connectableLocalProfile', {
      ...owners.consistency, ...owners.core, hasPaidEntitlement: owners.api.hasPaidEntitlement,
    }).connectableLocalProfile,
    ...load('src/vpn/androidRoutingSafety.ts', 'androidVpnProfileRequiresRefresh,androidVpnProfileWithinBinderBudget'),
  });
  return module.useVpnProfileState({ accessToken: 'A', userId: 'A', hasVpnAccess: true,
    knownEntitlement: paidAccess, isCurrentSessionOperation: () => true,
    onDeviceRevoked: async () => {}, onProfileRefreshFailed: () => {},
    onProfileRotationRequired: () => {}, onSubscriptionRequired: () => {},
    profileRefreshMs: 1, requestVpnPermission: async () => true,
    routingMode: 'default', selectedLocationId: 'de',
  });
}
function connectEntry(h, platform, nativeConnect, timeout = promise => promise, overrides = {}) {
  const ts = require('typescript');
  const file = path.join(process.env.VEX_KEY_ADMISSION_ENTRY_ROOT || sourceRoot, 'src/vpn/useVpnConnectionFlow.ts');
  const text = fs.readFileSync(file, 'utf8');
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  let callback;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && node.name.getText(source) === 'connectProfileWithEndpointFallback') {
      assert.equal(callback, undefined); callback = node.initializer.arguments[0].getText(source);
    }
    ts.forEachChild(node, visit);
  }
  visit(source); assert.ok(callback);
  const owners = profileOwners(h);
  const dependencies = {
    ...owners.api, ...owners.consistency,
    ...load('src/vpn/androidRoutingSafety.ts', 'androidVpnProfileWithinBinderBudget'),
    ...load('src/vpn/connectionFallback.ts', 'connectionAttemptsForProfile,isVpnTransportFallbackError,profileEndpoint'),
    ...owners.session,
    Platform: { OS: platform }, mountedRef: { current: true },
    session: { accessToken: 'A', user: { id: 'A' } }, isCurrentSessionOperation: () => true,
    requireCurrentSession: () => {}, prepareClientNetworkDiagnostics: async () => {},
    getVpnApplicationSelection: async () => ({ mode: 'all', packageNames: [] }),
    dynamicRouteRuntime: { prepare: async () => {}, attempts: profile => [{ profile }], clearActive: () => {} },
    connectVpn: nativeConnect, getVpnStatus: async () => ({ state: 'disconnected' }),
    withTimeout: timeout, connectAttemptTimeoutMs: 1000, antiLeakEnabled: true,
    waitForVerifiedVpnConnection: async status => status,
    withLastSuccessfulEndpoint: owners.core.withLastSuccessfulEndpoint,
    ...overrides,
  };
  const compiled = stripTypeScriptTypes('const connect = ' + callback + ';');
  return new Function(...Object.keys(dependencies), compiled + '; return connect;')(...Object.values(dependencies));
}
function localProfile(tunnel) {
  return { ...tunnel, config: tunnel.config.replace('[Interface]', '[Interface]\nHeaderProtectionKey = isolated-fixture'), locationId: 'de', routingMode: 'default', entitlement: paidAccess, source: 'local', cacheSavedAtMs: Date.now() };
}

for (const platform of ['android', 'ios']) {
  for (const interrupted of ['ordinary-rotate-before-commit', 'ordinary-rotate-after-commit']) {
    for (const cache of ['memory', 'persistent-hot', 'query-hook', 'hot-hook']) {
      test(platform + ': ' + cache + ' reconciles ' + interrupted + ' before returning an old key', { timeout: 2000 }, async () => {
        const h = harness(platform);
        const old = localProfile(await h.prepare('A'));
        const owners = profileOwners(h, cache.includes('hot') ? old : undefined);
        if (cache === 'memory') await owners.profiles.resolveVpnProfile('A', paidAccess, 'de', { userId: 'A', forceRefresh: true });
        h.interruptConfirmation(interrupted);
        await assert.rejects(h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A'), /rotation response lost/);
        const generations = h.generations();
        const pending = JSON.parse([...h.saved.entries()].find(([key]) => key.endsWith('.pending'))[1]);
        h.interruptConfirmation(undefined);
        const fresh = cache.endsWith('hook')
          ? await profileState(h, platform, cache === 'query-hook' ? old : null, cache === 'hot-hook' ? old : null).resolveConnectableVpnProfile('de')
          : await owners.profiles.resolveVpnProfile('A', paidAccess, 'de', { userId: 'A' });
        assert.ok(fresh.config.includes('PrivateKey = ' + pending.privateKey), 'the lost-response key, not the stale cached pair, must reach the caller');
        assert.equal(fresh.source, 'api');
        assert.equal(h.generations(), generations, 'reconciliation must reuse the durable pair');
        assert.equal(h.rotations.length, interrupted.endsWith('before-commit') ? 2 : 1);
        assert.equal([...h.saved.keys()].some(key => key.endsWith('.pending')), false);
      });
    }
  }
  test(platform + ': pending journal blocks actual native dispatch without hidden repair', async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    h.interruptConfirmation('ordinary-rotate-after-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A'));
    const requests = h.requests.length, rotations = h.rotations.length;
    let calls = 0;
    await assert.rejects(connectEntry(h, platform, async () => { calls++; return { state: 'connected' }; })(old), h.api.VpnProfileKeyChangedError);
    assert.equal(calls, 0); assert.equal(h.rotations.length, rotations);
    assert.equal(h.requests.length, requests, 'dispatch admission is local after account setup');
    assert.equal([...h.saved.keys()].some(key => key.endsWith('.pending')), true);
  });
  test(platform + ': rotation after preparation fences actual native dispatch', async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    await h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A');
    let calls = 0;
    await assert.rejects(connectEntry(h, platform, async () => { calls++; return { state: 'connected' }; })(old), h.api.VpnProfileKeyChangedError);
    assert.equal(calls, 0);
  });
  test(platform + ': admitted native promise retains the existing rotation owner', { timeout: 2000 }, async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    const reached = gate(), release = gate();
    const connected = connectEntry(h, platform, async () => { reached.resolve(); await release.promise; return { state: 'connected' }; })(old);
    await reached.promise;
    const rotated = h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A');
    await new Promise(setImmediate);
    assert.equal(h.rotations.length, 0, 'rotation must wait for the real native promise');
    release.resolve(); await connected; await rotated;
    assert.equal(h.rotations.length, 1);
  });
  test(platform + ': timed-out queued admission cannot start native later', { timeout: 2000 }, async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    const lookup = gate(); h.holdLookup(lookup);
    const rotated = h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A');
    await new Promise(setImmediate);
    const expired = gate(); let calls = 0;
    const timeout = (promise, _ms, label) => label === 'VPN connect timed out.'
      ? Promise.race([promise, expired.promise.then(() => { throw Error('fixture deadline'); })]) : promise;
    const connecting = connectEntry(h, platform, async () => { calls++; return { state: 'connected' }; }, timeout)(old);
    const rejected = assert.rejects(connecting, error => error.cause?.message === 'fixture deadline');
    await new Promise(setImmediate); expired.resolve(); await rejected;
    lookup.resolve(); await rotated; await new Promise(setImmediate);
    assert.equal(calls, 0);
  });
  test(platform + ': timing starts at admitted native dispatch and records interface-up before verification', { timeout: 2000 }, async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    const reached = gate(), release = gate(); let now = 1000, minimumHandshake;
    const owner = h.scoped.withVpnAccountIdentity({ userId: 'A', platform, locationId: 'de', loadOwnedDevices: async () => [] }, async () => { reached.resolve(); await release.promise; });
    await reached.promise;
    const connecting = connectEntry(h, platform, async () => { assert.equal(now, 9000); now = 10000; return { state: 'connected' }; }, undefined, {
      Date: { now: () => now }, waitForVerifiedVpnConnection: async (status, _getStatus, options) => { minimumHandshake = options.minimumHandshakeEpochMillis; now = 11000; return status; },
    })(old);
    await new Promise(setImmediate); now = 9000; release.resolve(); await owner;
    const result = await connecting;
    assert.equal(result.nativeStartMs, 9000); assert.equal(result.interfaceUpMs, 10000);
    assert.equal(result.verificationCompletedMs, 11000); assert.equal(minimumHandshake, 7000);
  });
  test(platform + ': borrower timeout retains ownership until the real native promise settles', { timeout: 2000 }, async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    const reached = gate(), release = gate(), expired = gate();
    const timeout = (promise, _ms, label) => label === 'VPN connect timed out.' ? Promise.race([promise, expired.promise.then(() => { throw Error('fixture deadline'); })]) : promise;
    const connecting = connectEntry(h, platform, async () => { reached.resolve(); await release.promise; return { state: 'connected' }; }, timeout)(old);
    const rejected = assert.rejects(connecting, /fixture deadline/);
    await reached.promise; expired.resolve(); await rejected;
    const rotating = h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A');
    await new Promise(setImmediate); assert.equal(h.rotations.length, 0);
    release.resolve(); await rotating; assert.equal(h.rotations.length, 1);
  });
  test(platform + ': matching material accepts PSK-only epoch advancement but rejects ambiguous or foreign keys', async () => {
    const h = harness(platform), profile = localProfile(await h.prepare('A'));
    assert.equal(await h.api.vpnProfileKeyIsCurrent('A', profile, { userId: 'A' }), true);
    for (const keyEpoch of [0, undefined]) assert.equal(await h.api.vpnProfileKeyIsCurrent('A', { ...profile, device: { ...profile.device, keyEpoch } }, { userId: 'A' }), true, 'legacy unknown epoch must retain matching-key compatibility');
    assert.equal(await h.api.vpnProfileKeyIsCurrent('A', { ...profile, device: { ...profile.device, keyEpoch: profile.device.keyEpoch + 1 } }, { userId: 'A' }), true);
    for (const changed of [
      { ...profile, config: profile.config + '\nPrivateKey = ' + legacyPair.privateKey },
      { ...profile, config: profile.config.replace(legacyPair.privateKey, key(32)) },
      { ...profile, device: { ...profile.device, userId: 'B' } },
      { ...profile, device: { ...profile.device, publicKey: key(33) } },
      { ...profile, device: { ...profile.device, externalDeviceId: 'native-foreign' } },
    ]) assert.equal(await h.api.vpnProfileKeyIsCurrent('A', changed, { userId: 'A' }), false);
    h.setReadFailure(true);
    await assert.rejects(h.api.vpnProfileKeyIsCurrent('A', profile, { userId: 'A' }), /locked/, 'storage errors must not be interpreted as absence');
  });
}

function stagedActivation(connect, disconnect, busy) {
  const ts = require('typescript');
  const file = path.join(process.env.VEX_KEY_ADMISSION_ENTRY_ROOT || sourceRoot, 'src/vpn/useVpnConnection.ts');
  const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  let activate;
  function visit(node) {
    if (ts.isPropertyAssignment(node) && node.name.getText(source) === 'activate') {
      assert.equal(activate, undefined); activate = node.initializer.getText(source);
    }
    ts.forEachChild(node, visit);
  }
  visit(source); assert.ok(activate);
  const bindings = { requireCurrentSession: () => {}, isConnected: true,
    setActiveProfile: () => {}, cacheProfile: () => {}, vpnOperationInFlightRef: busy,
    disconnectVpn: disconnect, connectProfileWithEndpointFallback: connect,
    isCurrentSessionOperation: () => true, cancelled: false,
    setVpnStatus: () => {}, reportVpnConnectEvent: () => {},
  };
  return new Function(...Object.keys(bindings), stripTypeScriptTypes('const activate = ' + activate + ';') + ';return activate;')(...Object.values(bindings));
}
for (const platform of ['android', 'ios']) {
  test(platform + ': absent account mapping cannot allocate a key or call API during actual dispatch', async () => {
    const h = harness(platform), old = localProfile(await h.prepare('A'));
    for (const key of h.saved.keys()) if (key.startsWith('vex.vpn.account_registration.')) h.saved.delete(key);
    const requests = h.requests.length, writes = h.writes.length, generations = h.generations();
    let nativeCalls = 0;
    await assert.rejects(connectEntry(h, platform, async () => { nativeCalls++; })(old), h.api.VpnProfileKeyChangedError);
    assert.equal(nativeCalls, 0); assert.equal(h.requests.length, requests);
    assert.equal(h.writes.length, writes); assert.equal(h.generations(), generations);
  });
}
for (const pending of [false, true]) test('staged PSK activation admits the key before teardown, pending=' + pending, async () => {
  const h = harness('android'), old = localProfile(await h.prepare('A'));
  if (pending) {
    h.interruptConfirmation('ordinary-rotate-before-commit');
    await assert.rejects(h.api.rotateManagedVpnKey('A', old.device.id, old.device.keyEpoch, () => true, 'A'));
  }
  const order = [], busy = { current: false };
  const connect = connectEntry(h, 'android', async () => { order.push('connect'); return { state: 'connected' }; });
  const activate = stagedActivation(connect, async options => { assert.equal(options.releaseAntiLeak, false); order.push('disconnect'); }, busy);
  if (pending) {
    await assert.rejects(activate({ profile: old }), h.api.VpnProfileKeyChangedError);
    assert.deepEqual(order, [], 'an unadmitted key must preserve the current tunnel');
  } else {
    await activate({ profile: old }); assert.deepEqual(order, ['disconnect', 'connect']);
  }
  assert.equal(busy.current, false);
});

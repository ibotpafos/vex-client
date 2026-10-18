const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Buffer } = require('node:buffer');
const test = require('node:test');
const ts = require('typescript');

const storageKey = 'vex.auth.device_identity.v1';
const source = ts.transpileModule(fs.readFileSync('src/native/deviceIdentity.ts', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
}).outputText;

function load(options = {}) {
  const values = options.values || new Map();
  const metrics = { entropy: 0, writes: 0 };
  const module = { exports: {} };
  const secureStore = {
    async getItemAsync(key) {
      if (options.readFails) throw new Error('secure storage unavailable');
      return values.get(key) ?? null;
    },
    async setItemAsync(key, value) {
      if (options.writeFails) throw new Error('secure storage unavailable');
      metrics.writes++; values.set(key, value);
    },
  };
  const nativeCrypto = {
    CryptoDigestAlgorithm: { SHA256: 'SHA-256' },
    async getRandomBytesAsync(size) {
      metrics.entropy++;
      if (options.entropyFails) throw new Error('native entropy unavailable');
      return new Uint8Array(crypto.randomBytes(size));
    },
    async digestStringAsync(algorithm, value) {
      assert.equal(algorithm, 'SHA-256');
      return crypto.createHash('sha256').update(value, 'utf8').digest('hex');
    },
  };
  vm.runInNewContext(source, {
    module, exports: module.exports,
    require(name) {
      if (name === '@/native/secureStore') return secureStore;
      if (name === 'expo-crypto') return nativeCrypto;
      if (name === 'react-native') return { Platform: { OS: options.platform || 'android' } };
      return require(name);
    },
    crypto: options.subtle ? { subtle: options.subtle } : undefined,
    Uint8Array, TextEncoder, btoa, atob,
  }, { filename: 'deviceIdentity.js' });
  return { create: module.exports.getOrCreateDeviceIdentity, values, metrics };
}

async function assertValidSignature(identity, payload = 'vex-device-binding-v1\nchallenge\nnonce\nregister\nустройство\npublic\nwg') {
  const signature = Buffer.from(await identity.sign(payload), 'base64url');
  assert.equal(signature.length, 64);
  const publicKey = crypto.createPublicKey({ key: JSON.parse(identity.publicKey), format: 'jwk' });
  assert.equal(crypto.verify('sha256', Buffer.from(payload), { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature), true);
  assert.equal(crypto.verify('sha256', Buffer.from(payload + 'changed'), { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature), false);
}

test('Hermes without SubtleCrypto persists a P-256 JWK and produces backend-compatible signatures', async () => {
  const runtime = load();
  const identity = await runtime.create();
  assert.equal(identity.keyType, 'p256_jwk');
  assert.equal(identity.trustLevel, 'software_secure_store');
  await assertValidSignature(identity);
  const stored = JSON.parse(runtime.values.get(storageKey));
  assert.equal(stored.version, 1);
  assert.equal(stored.privateKey.crv, 'P-256');
  assert.equal(runtime.metrics.entropy, 1);
  assert.equal(runtime.metrics.writes, 1);
});

test('concurrent first use shares one identity and a restart reuses it without entropy or writes', async () => {
  const runtime = load();
  const identities = await Promise.all(Array.from({ length: 12 }, () => runtime.create()));
  assert.equal(new Set(identities.map(identity => identity.publicKey)).size, 1);
  assert.equal(runtime.metrics.entropy, 1);
  assert.equal(runtime.metrics.writes, 1);
  const restarted = load({ values: runtime.values, platform: 'ios' });
  const identity = await restarted.create();
  assert.equal(identity.publicKey, identities[0].publicKey);
  assert.equal(restarted.metrics.entropy, 0);
  assert.equal(restarted.metrics.writes, 0);
  await assertValidSignature(identity);
});

test('native signing does not depend on a browser SubtleCrypto shim', async () => {
  const unavailable = () => { throw new Error('browser signing is unavailable'); };
  const runtime = load({ subtle: { generateKey: unavailable, importKey: unavailable, sign: unavailable } });
  await assertValidSignature(await runtime.create());
});

test('a native runtime preserves an existing WebCrypto identity and its exact public-key string', async () => {
  const web = load({ platform: 'web', subtle: crypto.webcrypto.subtle });
  const original = await web.create();
  const bytesBefore = web.values.get(storageKey);
  const native = load({ values: web.values });
  const migrated = await native.create();
  assert.equal(migrated.publicKey, original.publicKey);
  assert.equal(native.values.get(storageKey), bytesBefore);
  assert.equal(native.metrics.entropy, 0);
  assert.equal(native.metrics.writes, 0);
  await assertValidSignature(migrated);
  await assertValidSignature(original);
});

test('WebCrypto can reopen and sign a natively generated identity without rotating it', async () => {
  const native = load(); const original = await native.create();
  const web = load({ platform: 'web', values: native.values, subtle: crypto.webcrypto.subtle });
  const identity = await web.create();
  assert.equal(identity.publicKey, original.publicKey);
  assert.equal(web.metrics.writes, 0);
  await assertValidSignature(identity);
});

test('invalid stored keys, mismatched public coordinates and unreadable storage cannot replace an identity', async () => {
  const original = load(); await original.create();
  for (const mutate of [
    stored => { stored.privateKey.d = 'A'.repeat(43); },
    stored => { stored.privateKey.x = 'A'.repeat(43); },
    stored => { stored.publicKey = JSON.stringify({ ...JSON.parse(stored.publicKey), y: 'A'.repeat(43) }); },
    stored => { stored.version = 2; },
  ]) {
    const stored = JSON.parse(original.values.get(storageKey)); mutate(stored);
    const serialized = JSON.stringify(stored);
    const runtime = load({ values: new Map([[storageKey, serialized]]) });
    await assert.rejects(runtime.create());
    assert.equal(runtime.values.get(storageKey), serialized);
    assert.equal(runtime.metrics.entropy, 0); assert.equal(runtime.metrics.writes, 0);
  }
  const corrupted = load({ values: new Map([[storageKey, '{']]) });
  await assert.rejects(corrupted.create());
  assert.equal(corrupted.metrics.writes, 0);
  const unreadable = load({ readFails: true });
  await assert.rejects(unreadable.create(), /secure storage unavailable/);
  assert.equal(unreadable.metrics.entropy, 0);
});

test('entropy and persistence failures propagate and a later retry can recover without weak randomness', async () => {
  const options = { entropyFails: true };
  const runtime = load(options);
  await assert.rejects(runtime.create(), /native entropy unavailable/);
  assert.equal(runtime.values.size, 0);
  options.entropyFails = false;
  await assertValidSignature(await runtime.create());
  const failedWrite = load({ writeFails: true });
  await assert.rejects(failedWrite.create(), /secure storage unavailable/);
  assert.equal(failedWrite.values.size, 0);
});

test('an insecure web environment does not gain the native signing fallback', async () => {
  const web = load({ platform: 'web' });
  assert.equal(await web.create(), null);
  assert.equal(web.metrics.entropy, 0); assert.equal(web.metrics.writes, 0);
});

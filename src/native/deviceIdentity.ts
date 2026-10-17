import * as SecureStore from '@/native/secureStore';
import * as Crypto from 'expo-crypto';
import { Platform } from 'react-native';
import { p256 } from '@noble/curves/nist.js';
import { hexToBytes } from '@noble/curves/utils.js';

const DEVICE_IDENTITY_STORAGE_KEY = 'vex.auth.device_identity.v1';
const DEVICE_IDENTITY_KEY_TYPE = 'p256_jwk';
const DEVICE_IDENTITY_TRUST_LEVEL = 'software_secure_store';
const DEVICE_IDENTITY_PAYLOAD_VERSION = 'vex-device-binding-v1';

type StoredDeviceIdentity = {
  version: 1;
  keyType: typeof DEVICE_IDENTITY_KEY_TYPE;
  trustLevel: typeof DEVICE_IDENTITY_TRUST_LEVEL;
  publicKey: string;
  privateKey: JsonWebKey;
};

export type DeviceIdentity = {
  keyType: typeof DEVICE_IDENTITY_KEY_TYPE;
  trustLevel: typeof DEVICE_IDENTITY_TRUST_LEVEL;
  publicKey: string;
  sign: (payload: string) => Promise<string>;
};

export type DeviceIdentityChallenge = {
  id: string;
  nonce: string;
  purpose: string;
};

let pendingIdentity: Promise<DeviceIdentity | null> | undefined;

export async function getOrCreateDeviceIdentity(): Promise<DeviceIdentity | null> {
  if (pendingIdentity) return pendingIdentity;
  const request = loadOrCreateDeviceIdentity();
  pendingIdentity = request;
  try {
    return await request;
  } finally {
    if (pendingIdentity === request) pendingIdentity = undefined;
  }
}

async function loadOrCreateDeviceIdentity(): Promise<DeviceIdentity | null> {
  const native = Platform.OS === 'android' || Platform.OS === 'ios';
  const subtle = native ? undefined : globalThis.crypto?.subtle;
  if (!subtle && !native) {
    return null;
  }
  const stored = await readStoredDeviceIdentity();
  if (stored) {
    return subtle ? identityFromStored(stored, subtle) : nativeIdentityFromStored(stored);
  }
  const generated = subtle ? await generateStoredDeviceIdentity(subtle) : await generateNativeStoredDeviceIdentity();
  await SecureStore.setItemAsync(DEVICE_IDENTITY_STORAGE_KEY, JSON.stringify(generated));
  return subtle ? identityFromStored(generated, subtle) : nativeIdentityFromStored(generated);
}

export function deviceIdentitySignaturePayload(
  challenge: DeviceIdentityChallenge,
  installationId: string,
  identityPublicKey: string,
  wireGuardPublicKey: string,
): string {
  return [
    DEVICE_IDENTITY_PAYLOAD_VERSION,
    challenge.id.trim(),
    challenge.nonce.trim(),
    challenge.purpose.trim(),
    installationId.trim(),
    identityPublicKey.trim(),
    wireGuardPublicKey.trim(),
  ].join('\n');
}

async function readStoredDeviceIdentity(): Promise<StoredDeviceIdentity | null> {
  const raw = await SecureStore.getItemAsync(DEVICE_IDENTITY_STORAGE_KEY);
  if (!raw) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as StoredDeviceIdentity;
    if (parsed?.version === 1 && parsed.keyType === DEVICE_IDENTITY_KEY_TYPE && parsed.publicKey && parsed.privateKey) {
      return parsed;
    }
  } catch {}
  throw new Error('Сохранённая подпись устройства повреждена.');
}

async function generateNativeStoredDeviceIdentity(): Promise<StoredDeviceIdentity> {
  // The async Expo API uses the native CSPRNG even in development. Never use
  // the synchronous API's remote-debugger Math.random fallback for key material.
  const seedLength = p256.lengths.seed;
  if (!seedLength) throw new Error('Генератор подписи устройства недоступен.');
  const secretKey = p256.utils.randomSecretKey(await Crypto.getRandomBytesAsync(seedLength));
  const publicJwk = nativePublicJwk(secretKey);
  return {
    version: 1,
    keyType: DEVICE_IDENTITY_KEY_TYPE,
    trustLevel: DEVICE_IDENTITY_TRUST_LEVEL,
    publicKey: stablePublicJwk(publicJwk),
    privateKey: { ...publicJwk, d: bytesToBase64Url(secretKey), ext: true, key_ops: ['sign'] },
  };
}

function nativePublicJwk(secretKey: Uint8Array): JsonWebKey {
  const publicKey = p256.getPublicKey(secretKey, false);
  return { kty: 'EC', crv: 'P-256', x: bytesToBase64Url(publicKey.slice(1, 33)), y: bytesToBase64Url(publicKey.slice(33)) };
}

function nativeIdentityFromStored(stored: StoredDeviceIdentity): DeviceIdentity {
  const jwk = stored.privateKey;
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || typeof jwk.d !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(jwk.d)) {
    throw new Error('Сохранённая подпись устройства повреждена.');
  }
  const secretKey = Uint8Array.from(atob(jwk.d.replace(/-/g, '+').replace(/_/g, '/') + '='), value => value.charCodeAt(0));
  if (!p256.utils.isValidSecretKey(secretKey) || bytesToBase64Url(secretKey) !== jwk.d) {
    throw new Error('Сохранённая подпись устройства повреждена.');
  }
  const publicJwk = nativePublicJwk(secretKey);
  // Reuse existing WebCrypto JWKs byte-for-byte; do not silently replace a
  // previously registered identity or sign with mismatched stored coordinates.
  if (stablePublicJwk(jwk) !== stablePublicJwk(publicJwk) || stablePublicJwk(JSON.parse(stored.publicKey)) !== stablePublicJwk(publicJwk)) {
    throw new Error('Сохранённая подпись устройства повреждена.');
  }
  return {
    keyType: stored.keyType,
    trustLevel: stored.trustLevel,
    publicKey: stored.publicKey,
    sign: async payload => {
      const digest = hexToBytes(await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, payload));
      return bytesToBase64Url(p256.sign(digest, secretKey, { prehash: false, format: 'compact' }));
    },
  };
}

async function generateStoredDeviceIdentity(subtle: SubtleCrypto): Promise<StoredDeviceIdentity> {
  const keyPair = await subtle.generateKey(
    {
      name: 'ECDSA',
      namedCurve: 'P-256',
    },
    true,
    ['sign', 'verify'],
  );
  const publicJwk = await subtle.exportKey('jwk', keyPair.publicKey);
  const privateJwk = await subtle.exportKey('jwk', keyPair.privateKey);
  return {
    version: 1,
    keyType: DEVICE_IDENTITY_KEY_TYPE,
    trustLevel: DEVICE_IDENTITY_TRUST_LEVEL,
    publicKey: stablePublicJwk(publicJwk),
    privateKey: privateJwk,
  };
}

async function identityFromStored(stored: StoredDeviceIdentity, subtle: SubtleCrypto): Promise<DeviceIdentity> {
  const privateKey = await subtle.importKey(
    'jwk',
    stored.privateKey,
    {
      name: 'ECDSA',
      namedCurve: 'P-256',
    },
    false,
    ['sign'],
  );
  return {
    keyType: stored.keyType,
    trustLevel: stored.trustLevel,
    publicKey: stored.publicKey,
    sign: async (payload: string) => {
      const signature = await subtle.sign(
        {
          name: 'ECDSA',
          hash: 'SHA-256',
        },
        privateKey,
        new TextEncoder().encode(payload),
      );
      return bytesToBase64Url(new Uint8Array(signature));
    },
  };
}

function stablePublicJwk(jwk: JsonWebKey): string {
  return JSON.stringify({
    kty: jwk.kty,
    crv: jwk.crv,
    x: jwk.x,
    y: jwk.y,
  });
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.slice(offset, offset + chunkSize));
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

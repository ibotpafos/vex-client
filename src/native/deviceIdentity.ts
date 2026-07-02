import * as SecureStore from '@/native/secureStore';

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

export async function getOrCreateDeviceIdentity(): Promise<DeviceIdentity | null> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) {
    return null;
  }
  const stored = await readStoredDeviceIdentity();
  if (stored) {
    return identityFromStored(stored, subtle);
  }
  const generated = await generateStoredDeviceIdentity(subtle);
  await SecureStore.setItemAsync(DEVICE_IDENTITY_STORAGE_KEY, JSON.stringify(generated));
  return identityFromStored(generated, subtle);
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
  const raw = await SecureStore.getItemAsync(DEVICE_IDENTITY_STORAGE_KEY).catch(() => null);
  if (!raw) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as StoredDeviceIdentity;
    if (parsed?.version === 1 && parsed.keyType === DEVICE_IDENTITY_KEY_TYPE && parsed.publicKey && parsed.privateKey) {
      return parsed;
    }
  } catch {}
  return null;
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

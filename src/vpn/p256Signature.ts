export type P256SignatureVerifier = (payloadBase64: string, signatureBase64: string, subjectPublicKeyInfoBase64: string) => Promise<boolean>;

export async function verifyP256WithWebCrypto(
  payloadBase64: string,
  signatureBase64: string,
  subjectPublicKeyInfoBase64: string,
): Promise<boolean> {
  const subtle = globalThis.crypto?.subtle;
  const payload = decodeBase64(payloadBase64);
  const signatureDer = decodeBase64(signatureBase64);
  const keyData = decodeBase64(subjectPublicKeyInfoBase64);
  const signatureRaw = signatureDer ? ecdsaDerToP1363(signatureDer) : null;
  if (!subtle || !payload || !keyData || !signatureRaw) return false;
  try {
    const key = await subtle.importKey('spki', arrayBuffer(keyData), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, arrayBuffer(signatureRaw), arrayBuffer(payload));
  } catch {
    return false;
  }
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function decodeBase64(value: string): Uint8Array | null {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) return null;
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

function ecdsaDerToP1363(der: Uint8Array): Uint8Array | null {
  if (der.length < 8 || der[0] !== 0x30 || der[1] !== der.length - 2) return null;
  let offset = 2;
  const r = readDerInteger(der, offset);
  if (!r) return null;
  offset = r.nextOffset;
  const s = readDerInteger(der, offset);
  if (!s || s.nextOffset !== der.length) return null;
  const raw = new Uint8Array(64);
  raw.set(r.value, 32 - r.value.length);
  raw.set(s.value, 64 - s.value.length);
  return raw;
}

function readDerInteger(der: Uint8Array, offset: number): Readonly<{ value: Uint8Array; nextOffset: number }> | null {
  if (der[offset] !== 0x02) return null;
  const length = der[offset + 1];
  const start = offset + 2;
  const end = start + length;
  if (!length || end > der.length) return null;
  let value = der.slice(start, end);
  const hasSignPadding = value.length > 1 && value[0] === 0;
  if (hasSignPadding) value = value.slice(1);
  if (!value.length || value.length > 32 || (!hasSignPadding && (value[0] & 0x80) !== 0)) return null;
  return { value, nextOffset: end };
}

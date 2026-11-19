import * as Crypto from 'expo-crypto';

export function generateRandomString(length: number): string {
  const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  let text = '';
  const runtimeCrypto = globalThis.crypto;
  if (typeof runtimeCrypto?.getRandomValues !== 'function') {
    throw new Error('Secure random generator is unavailable.');
  }
  const values = runtimeCrypto.getRandomValues(new Uint8Array(length));
  for (let i = 0; i < length; i++) {
    text += possible.charAt(values[i] % possible.length);
  }
  return text;
}

export async function sha256(plain: string): Promise<ArrayBuffer> {
  const hex = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, plain);
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes.buffer;
}

export function base64urlencode(a: ArrayBuffer): string {
  return bytesToBase64(new Uint8Array(a))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

export function bytesToBase64(bytes: Uint8Array): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let output = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const byte1 = bytes[i];
    const byte2 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const byte3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const value = (byte1 << 16) | (byte2 << 8) | byte3;
    output += alphabet[(value >> 18) & 63];
    output += alphabet[(value >> 12) & 63];
    output += i + 1 < bytes.length ? alphabet[(value >> 6) & 63] : '=';
    output += i + 2 < bytes.length ? alphabet[value & 63] : '=';
  }
  return output;
}

export async function generateChallenge(verifier: string): Promise<string> {
  const hashed = await sha256(verifier);
  return base64urlencode(hashed);
}

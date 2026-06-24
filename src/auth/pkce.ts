export function generateRandomString(length: number): string {
  const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  let text = '';
  if (typeof window !== 'undefined' && window.crypto && window.crypto.getRandomValues) {
    const values = new Uint8Array(length);
    window.crypto.getRandomValues(values);
    for (let i = 0; i < length; i++) {
      text += possible.charAt(values[i] % possible.length);
    }
  } else {
    for (let i = 0; i < length; i++) {
      text += possible.charAt(Math.floor(Math.random() * possible.length));
    }
  }
  return text;
}

export async function sha256(plain: string): Promise<ArrayBuffer> {
  const data = encodeUtf8(plain);
  const subtle = typeof window !== 'undefined'
    ? window.crypto?.subtle
    : (globalThis as typeof globalThis & { crypto?: Crypto }).crypto?.subtle;
  if (subtle) {
    return await subtle.digest('SHA-256', data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
  }
  return sha256Fallback(data);
}

export function base64urlencode(a: ArrayBuffer): string {
  return bytesToBase64(new Uint8Array(a))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

export function encodeUtf8(value: string): Uint8Array {
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(value);
  }

  const encoded = unescape(encodeURIComponent(value));
  const bytes = new Uint8Array(encoded.length);
  for (let i = 0; i < encoded.length; i++) {
    bytes[i] = encoded.charCodeAt(i);
  }
  return bytes;
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

export function sha256Fallback(data: Uint8Array): ArrayBuffer {
  const words: number[] = [];
  const bitLength = data.length * 8;
  for (let i = 0; i < data.length; i++) {
    words[i >> 2] = (words[i >> 2] || 0) | (data[i] << (24 - (i % 4) * 8));
  }
  words[bitLength >> 5] = (words[bitLength >> 5] || 0) | (0x80 << (24 - (bitLength % 32)));
  words[(((bitLength + 64) >> 9) << 4) + 15] = bitLength;

  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  for (let i = 0; i < words.length; i += 16) {
    const w = new Array<number>(64);
    for (let j = 0; j < 16; j++) {
      w[j] = words[i + j] || 0;
    }
    for (let j = 16; j < 64; j++) {
      const s0 = rightRotate(w[j - 15], 7) ^ rightRotate(w[j - 15], 18) ^ (w[j - 15] >>> 3);
      const s1 = rightRotate(w[j - 2], 17) ^ rightRotate(w[j - 2], 19) ^ (w[j - 2] >>> 10);
      w[j] = add32(w[j - 16], s0, w[j - 7], s1);
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let j = 0; j < 64; j++) {
      const s1 = rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = add32(h, s1, ch, sha256RoundConstants[j], w[j]);
      const s0 = rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = add32(s0, maj);
      h = g;
      g = f;
      f = e;
      e = add32(d, temp1);
      d = c;
      c = b;
      b = a;
      a = add32(temp1, temp2);
    }

    h0 = add32(h0, a);
    h1 = add32(h1, b);
    h2 = add32(h2, c);
    h3 = add32(h3, d);
    h4 = add32(h4, e);
    h5 = add32(h5, f);
    h6 = add32(h6, g);
    h7 = add32(h7, h);
  }

  return wordsToArrayBuffer([h0, h1, h2, h3, h4, h5, h6, h7]);
}

const sha256RoundConstants = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function rightRotate(value: number, bits: number): number {
  return (value >>> bits) | (value << (32 - bits));
}

function add32(...values: number[]): number {
  return values.reduce((sum, value) => (sum + value) >>> 0, 0);
}

function wordsToArrayBuffer(words: number[]): ArrayBuffer {
  const bytes = new Uint8Array(words.length * 4);
  words.forEach((word, index) => {
    bytes[index * 4] = (word >>> 24) & 255;
    bytes[index * 4 + 1] = (word >>> 16) & 255;
    bytes[index * 4 + 2] = (word >>> 8) & 255;
    bytes[index * 4 + 3] = word & 255;
  });
  return bytes.buffer;
}

export async function generateChallenge(verifier: string): Promise<string> {
  const hashed = await sha256(verifier);
  return base64urlencode(hashed);
}

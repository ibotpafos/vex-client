import * as ExpoCrypto from 'expo-crypto';

const runtimeCrypto = globalThis.crypto;

if (typeof runtimeCrypto?.getRandomValues !== 'function' || typeof runtimeCrypto?.randomUUID !== 'function') {
  Object.defineProperty(globalThis, 'crypto', {
    configurable: true,
    value: {
      ...runtimeCrypto,
      getRandomValues: ExpoCrypto.getRandomValues,
      randomUUID: ExpoCrypto.randomUUID,
    },
    writable: true,
  });
}

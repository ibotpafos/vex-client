import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { shouldUseMemoryOnlySensitiveWebStorage } from './secureStoreCore';

export const SENSITIVE_STORAGE_KEYS = [
  'vex.app.install_id.v1',
  'vex.app.install_reported.v1',
  'vex.auth.device_id',
  'vex.auth.device_identity.v1',
  'vex.vpn.legacy_key_owner.v1',
  'vex.auth.session.v1',
  'vex.auth.session.history.v1',
  'vex.auth.pkce.state',
  'vex.auth.pkce.verifier',
  'vex.billing.summary.v1',
  'vex.entitlement.v1',
  'vex.vpn.devices.v1',
  'vex.vpn.locations.v1',
  'vex.vpn.hot_profiles.v1',
];

const LOGOUT_PRESERVED_STORAGE_KEYS = new Set([
  'vex.app.install_id.v1',
  'vex.app.install_reported.v1',
  'vex.auth.device_id',
  'vex.auth.device_identity.v1',
  'vex.vpn.legacy_key_owner.v1',
]);

const LOGOUT_REQUIRED_STORAGE_KEYS = new Set([
  'vex.auth.session.v1',
  'vex.auth.session.history.v1',
]);

function shouldUseWebStorage(): boolean {
  return Platform.OS === 'web';
}

function getWebStorageItem(key: string): string | null {
  if (Platform.OS !== 'web') {
    return null;
  }
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function setWebStorageItem(key: string, value: string): void {
  if (Platform.OS !== 'web') {
    return;
  }
  try {
    localStorage.setItem(key, value);
  } catch {}
}

function deleteWebStorageItem(key: string, required = false): void {
  if (Platform.OS !== 'web') {
    return;
  }
  try {
    localStorage.removeItem(key);
  } catch (error) {
    if (required) throw error;
  }
}

async function clearRequiredLegacyWebSession(): Promise<void> {
  const results = await Promise.allSettled(
    [...LOGOUT_REQUIRED_STORAGE_KEYS].map(async (key) => deleteWebStorageItem(key, true)),
  );
  for (const result of results) {
    if (result.status === 'rejected') throw result.reason;
  }
}

const webSensitiveMemoryStorage = new Map<string, string>();
const itemOperations = new Map<string, Promise<void>>();

function withItemOperation<T>(key: string, run: () => Promise<T>): Promise<T> {
  const previous = itemOperations.get(key) ?? Promise.resolve();
  const pending = previous.then(run);
  const tail = pending.then(() => undefined, () => undefined);
  itemOperations.set(key, tail);
  void tail.then(() => {
    if (itemOperations.get(key) === tail) itemOperations.delete(key);
  });
  return pending;
}

export function getItemAsync(key: string): Promise<string | null> {
  return withItemOperation(key, () => readItem(key));
}

export function setItemAsync(key: string, value: string): Promise<void> {
  return withItemOperation(key, () => writeItem(key, value));
}

export function deleteItemAsync(key: string): Promise<void> {
  return withItemOperation(key, () => removeItem(key));
}

/** A synchronous transform and its write share one key slot in this JS runtime. */
export function updateItemAsync(key: string, update: (value: string | null) => string | null): Promise<void> {
  return withItemOperation(key, async () => {
    const current = await readItem(key);
    const next = update(current);
    if (next !== null && typeof next !== 'string') throw new TypeError('Stored item update must return a string or null.');
    if (next === current) return;
    if (next === null) await removeItem(key);
    else await writeItem(key, next);
  });
}

function shouldUseMemoryOnlyWebStorage(key: string): boolean {
  return shouldUseMemoryOnlySensitiveWebStorage(Platform.OS, key, SENSITIVE_STORAGE_KEYS);
}

async function readItem(key: string): Promise<string | null> {
  if (shouldUseMemoryOnlyWebStorage(key)) {
    if (webSensitiveMemoryStorage.has(key)) {
      return webSensitiveMemoryStorage.get(key) ?? null;
    }
    const legacyValue = getWebStorageItem(key);
    if (legacyValue) {
      deleteWebStorageItem(key);
      webSensitiveMemoryStorage.set(key, legacyValue);
      return legacyValue;
    }
    return null;
  }
  if (shouldUseWebStorage()) {
    return getWebStorageItem(key);
  }
  return SecureStore.getItemAsync(key);
}

async function writeItem(key: string, value: string): Promise<void> {
  if (shouldUseMemoryOnlyWebStorage(key)) {
    // A new login must not leave the previous account in either legacy copy.
    // History writes are best effort, so verify both before publishing primary.
    if (key === 'vex.auth.session.v1') await clearRequiredLegacyWebSession();
    webSensitiveMemoryStorage.set(key, value);
    deleteWebStorageItem(key);
    return;
  }
  if (shouldUseWebStorage()) {
    setWebStorageItem(key, value);
    return;
  }
  return SecureStore.setItemAsync(key, value);
}

async function removeItem(key: string): Promise<void> {
  if (shouldUseMemoryOnlyWebStorage(key)) {
    webSensitiveMemoryStorage.delete(key);
    deleteWebStorageItem(key, LOGOUT_REQUIRED_STORAGE_KEYS.has(key));
    return;
  }
  if (shouldUseWebStorage()) {
    deleteWebStorageItem(key, LOGOUT_REQUIRED_STORAGE_KEYS.has(key));
    return;
  }
  return SecureStore.deleteItemAsync(key);
}

export async function clearSecureKeys(keys: readonly string[]): Promise<void> {
  const results = await Promise.allSettled(keys.map((key) => deleteItemAsync(key)));

  // Both durable session copies must be removed before logout can succeed.
  // Attempt every key first; unrelated cache cleanup remains best effort.
  for (let index = 0; index < results.length; index += 1) {
    const result = results[index];
    if (LOGOUT_REQUIRED_STORAGE_KEYS.has(keys[index]) && result.status === 'rejected') {
      throw result.reason;
    }
  }
}

export async function clearSensitiveStorageHistory(): Promise<void> {
  await clearSecureKeys(SENSITIVE_STORAGE_KEYS.filter((key) => !LOGOUT_PRESERVED_STORAGE_KEYS.has(key)));
}

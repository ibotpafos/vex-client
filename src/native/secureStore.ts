import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { shouldUseMemoryOnlySensitiveWebStorage } from './secureStoreCore';

export const SENSITIVE_STORAGE_KEYS = [
  'vex.app.install_id.v1',
  'vex.app.install_reported.v1',
  'vex.auth.device_id',
  'vex.auth.device_identity.v1',
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

function deleteWebStorageItem(key: string): void {
  if (Platform.OS !== 'web') {
    return;
  }
  try {
    localStorage.removeItem(key);
  } catch {}
}

function clearWebStorageItems(keys: readonly string[]): void {
  for (const key of keys) {
    webSensitiveMemoryStorage.delete(key);
    deleteWebStorageItem(key);
  }
}

const webSensitiveMemoryStorage = new Map<string, string>();

function shouldUseMemoryOnlyWebStorage(key: string): boolean {
  return shouldUseMemoryOnlySensitiveWebStorage(Platform.OS, key, SENSITIVE_STORAGE_KEYS);
}

export async function getItemAsync(key: string): Promise<string | null> {
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

export async function setItemAsync(key: string, value: string): Promise<void> {
  if (shouldUseMemoryOnlyWebStorage(key)) {
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

export async function deleteItemAsync(key: string): Promise<void> {
  if (shouldUseMemoryOnlyWebStorage(key)) {
    webSensitiveMemoryStorage.delete(key);
    deleteWebStorageItem(key);
    return;
  }
  if (shouldUseWebStorage()) {
    deleteWebStorageItem(key);
    return;
  }
  return SecureStore.deleteItemAsync(key);
}

export async function clearSecureKeys(keys: readonly string[]): Promise<void> {
  await Promise.all(keys.map((key) => deleteItemAsync(key).catch(() => undefined)));

  // На вебе сессия могла сохраниться в localStorage в промежуточных версиях.
  clearWebStorageItems(keys);
}

export async function clearSensitiveStorageHistory(): Promise<void> {
  await clearSecureKeys(SENSITIVE_STORAGE_KEYS.filter((key) => !LOGOUT_PRESERVED_STORAGE_KEYS.has(key)));
}

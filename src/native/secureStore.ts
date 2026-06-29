import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import {
  deleteTauriSensitiveStorageItem,
  getTauriSensitiveStorageItem,
  isTauriSensitiveStorageKey,
  setTauriSensitiveStorageItem,
  shouldUseMemoryOnlySensitiveWebStorage,
  type TauriInvoke,
  type WebStorageAdapter,
} from './secureStoreCore';
import { isTauriRuntime } from './tauriPlatform';

export const SENSITIVE_STORAGE_KEYS = [
  'vex.auth.device_id',
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

function shouldUseWebStorage(): boolean {
  return Platform.OS === 'web';
}


function shouldUseTauriSensitiveStorage(key: string): boolean {
  return isTauriRuntime() && isTauriSensitiveStorageKey(key);
}

async function getTauriInvoke(): Promise<TauriInvoke | null> {
  if (!isTauriRuntime()) {
    return null;
  }
  try {
    const api = await import('@tauri-apps/api/core');
    return api.invoke;
  } catch {
    return null;
  }
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

const webStorageAdapter: WebStorageAdapter = {
  getItem: getWebStorageItem,
  setItem: setWebStorageItem,
  deleteItem: deleteWebStorageItem,
};

const webSensitiveMemoryStorage = new Map<string, string>();

function shouldUseMemoryOnlyWebStorage(key: string): boolean {
  return shouldUseMemoryOnlySensitiveWebStorage(Platform.OS, isTauriRuntime(), key, SENSITIVE_STORAGE_KEYS);
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
  if (shouldUseTauriSensitiveStorage(key)) {
    const invoke = await getTauriInvoke();
    if (invoke) {
      return getTauriSensitiveStorageItem(key, invoke, webStorageAdapter);
    }
    const legacyValue = getWebStorageItem(key);
    if (legacyValue) {
      return legacyValue;
    }
    throw new Error('Tauri secure storage is unavailable.');
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
  if (shouldUseTauriSensitiveStorage(key)) {
    const invoke = await getTauriInvoke();
    if (invoke) {
      return setTauriSensitiveStorageItem(key, value, invoke, webStorageAdapter);
    }
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
  if (shouldUseTauriSensitiveStorage(key)) {
    const invoke = await getTauriInvoke();
    if (invoke) {
      return deleteTauriSensitiveStorageItem(key, invoke, webStorageAdapter);
    }
  }
  if (shouldUseWebStorage()) {
    deleteWebStorageItem(key);
    return;
  }
  return SecureStore.deleteItemAsync(key);
}

export async function clearSecureKeys(keys: readonly string[]): Promise<void> {
  for (const key of keys) {
    await deleteItemAsync(key);
  }

  // На вебе сессия могла сохраниться в localStorage в промежуточных версиях.
  clearWebStorageItems(keys);
}

export async function clearSensitiveStorageHistory(): Promise<void> {
  await clearSecureKeys(SENSITIVE_STORAGE_KEYS);
}

export type TauriInvoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

export type WebStorageAdapter = {
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => void;
  deleteItem: (key: string) => void;
};

export function isTauriSensitiveStorageKey(key: string): boolean {
  return (
    key.startsWith('vex.auth.')
    || key.startsWith('vex.billing.')
    || key.startsWith('vex.entitlement.')
    || key.startsWith('vex.vpn.')
  );
}

export function shouldUseMemoryOnlySensitiveWebStorage(
  platformOS: string,
  isTauri: boolean,
  key: string,
  sensitiveKeys: readonly string[],
): boolean {
  return platformOS === 'web' && !isTauri && sensitiveKeys.includes(key);
}

export async function getTauriSensitiveStorageItem(
  key: string,
  invoke: TauriInvoke,
  webStorage: WebStorageAdapter,
): Promise<string | null> {
  let storedValue: string | null;
  try {
    storedValue = await invoke<string | null>('secure_storage_get', { key });
  } catch (error) {
    const legacyValue = webStorage.getItem(key);
    if (legacyValue) {
      return legacyValue;
    }
    throw error;
  }
  if (storedValue) {
    return storedValue;
  }

  const legacyValue = webStorage.getItem(key);
  if (!legacyValue) {
    return null;
  }

  await invoke<boolean>('secure_storage_set', { key, value: legacyValue }).catch(() => false);
  return legacyValue;
}

export async function setTauriSensitiveStorageItem(
  key: string,
  value: string,
  invoke: TauriInvoke,
  webStorage: WebStorageAdapter,
): Promise<void> {
  const storedSecurely = await invoke<boolean>('secure_storage_set', { key, value }).catch(() => false);
  if (storedSecurely) {
    webStorage.deleteItem(key);
    return;
  }
  webStorage.setItem(key, value);
}

export async function deleteTauriSensitiveStorageItem(
  key: string,
  invoke: TauriInvoke,
  webStorage: WebStorageAdapter,
): Promise<void> {
  await invoke<boolean>('secure_storage_delete', { key }).catch(() => false);
  webStorage.deleteItem(key);
}

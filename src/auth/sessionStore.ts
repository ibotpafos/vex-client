import * as SecureStore from '../native/secureStore';
import type { AuthSession } from '../api/vexApi';
import { resetVpnProfileCache } from '../vpn/profile';
import { loadSessionFromStorage, saveSessionToStorage } from './sessionStoreCore';

export async function loadSession(): Promise<AuthSession | null> {
  return loadSessionFromStorage(SecureStore);
}

export async function saveSession(session: AuthSession): Promise<void> {
  await saveSessionToStorage(session, SecureStore);
}

export async function clearSession(): Promise<void> {
  resetVpnProfileCache();
  await SecureStore.clearSensitiveStorageHistory();
}

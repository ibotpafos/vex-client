import * as SecureStore from '../native/secureStore';
import type { AuthSession } from '../api/vexApi';
import { resetVpnProfileCache } from '../vpn/profile';
import { createSessionStore } from './sessionStoreCore';

const store = createSessionStore(SecureStore);

export async function loadSession(): Promise<AuthSession | null> {
  return store.load();
}

export async function saveSession(session: AuthSession): Promise<void> {
  await store.save(session);
}

export async function clearSession(): Promise<void> {
  resetVpnProfileCache();
  await store.clear();
}

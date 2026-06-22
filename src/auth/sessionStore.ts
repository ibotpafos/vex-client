import * as SecureStore from '../native/secureStore';
import type { AuthSession } from '../api/vexApi';
import { resetVpnProfileCache } from '../vpn/profile';

const sessionKey = 'vex.auth.session.v1';

export async function loadSession(): Promise<AuthSession | null> {
  const raw = await SecureStore.getItemAsync(sessionKey);
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as AuthSession;
    if (!parsed.accessToken || !parsed.user?.email) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

export async function saveSession(session: AuthSession): Promise<void> {
  await SecureStore.setItemAsync(sessionKey, JSON.stringify(session));
}

export async function clearSession(): Promise<void> {
  resetVpnProfileCache();
  await SecureStore.clearSensitiveStorageHistory();
}

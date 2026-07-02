import type { AuthSession } from '../api/vexApi';

export const sessionKey = 'vex.auth.session.v1';
export const sessionHistoryKey = 'vex.auth.session.history.v1';

export type SessionStorageAdapter = {
  getItemAsync: (key: string) => Promise<string | null>;
  setItemAsync: (key: string, value: string) => Promise<void>;
  deleteItemAsync: (key: string) => Promise<void>;
};

export async function loadSessionFromStorage(storage: SessionStorageAdapter): Promise<AuthSession | null> {
  const raw = await storage.getItemAsync(sessionKey);
  const primarySession = parseStoredSession(raw);
  if (primarySession) {
    return primarySession;
  }

  if (raw) {
    await storage.deleteItemAsync(sessionKey).catch(() => undefined);
  }

  const historyRaw = await storage.getItemAsync(sessionHistoryKey);
  const historySession = parseStoredSession(historyRaw);
  if (!historySession) {
    if (historyRaw) {
      await storage.deleteItemAsync(sessionHistoryKey).catch(() => undefined);
    }
    return null;
  }

  await storage.setItemAsync(sessionKey, JSON.stringify(historySession)).catch(() => undefined);
  return historySession;
}

export function parseStoredSession(raw: string | null): AuthSession | null {
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

export async function saveSessionToStorage(session: AuthSession, storage: SessionStorageAdapter): Promise<void> {
  const payload = JSON.stringify(session);
  await storage.setItemAsync(sessionKey, payload);
  await storage.setItemAsync(sessionHistoryKey, payload).catch(() => undefined);
}

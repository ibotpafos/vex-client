import type { AuthSession } from '../api/vexApi';

// A successful startup refresh revokes the stored token. Keep one response
// across provider remounts until its replacement can reach durable storage.
export function createSessionRestoreRefresh() {
  let flight: { accessToken: string; promise: Promise<AuthSession> } | null = null;
  return {
    run(accessToken: string, refresh: (token: string) => Promise<AuthSession>): Promise<AuthSession> {
      if (flight?.accessToken === accessToken) return flight.promise;
      const current = {
        accessToken,
        promise: Promise.resolve().then(() => refresh(accessToken)).catch((error: unknown) => {
          if (flight === current) flight = null;
          throw error;
        }),
      };
      flight = current;
      return current.promise;
    },
    invalidate() { flight = null; },
  };
}

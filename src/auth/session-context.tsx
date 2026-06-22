import React, { createContext, use, useCallback, useEffect, useMemo, useState, type PropsWithChildren } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { clearSession, loadSession, saveSession } from '@/auth/sessionStore';
import { loadSessionWithRetry } from '@/auth/sessionLoadRetry';
import { sessionLoadFailureDiagnosticsSnapshot } from '@/auth/sessionDiagnostics';
import { refreshSession as refreshApiSession, type AuthSession } from '@/api/vexApi';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';

type SessionContextValue = {
  isLoading: boolean;
  loadError: string | null;
  session: AuthSession | null;
  signIn: (nextSession: AuthSession) => Promise<void>;
  signOut: () => Promise<void>;
  refreshSession: () => Promise<AuthSession | null>;
};

const SessionContext = createContext<SessionContextValue | null>(null);

export function useSession() {
  const value = use(SessionContext);
  if (!value) {
    throw new Error('useSession must be wrapped in a <SessionProvider />');
  }
  return value;
}

export function SessionProvider({ children }: PropsWithChildren) {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<AuthSession | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const clearClientData = useCallback(() => {
    queryClient.removeQueries({ queryKey: ['entitlement'] });
    queryClient.removeQueries({ queryKey: ['vpn-profile'] });
    queryClient.removeQueries({ queryKey: ['vpn-locations'] });
    queryClient.removeQueries({ queryKey: ['vpn-devices'] });
    queryClient.removeQueries({ queryKey: ['billing-summary'] });
    queryClient.removeQueries({ queryKey: ['android-update'] });
    queryClient.removeQueries({ queryKey: ['ios-update'] });
    queryClient.removeQueries({ queryKey: ['desktop-update'] });
  }, [queryClient]);

  const applySignOutState = useCallback(async () => {
    await clearSession();
    clearClientData();
    setSession(null);
  }, [clearClientData]);

  useEffect(() => {
    let mounted = true;
    loadSessionWithRetry(loadSession)
      .catch((error) => {
        if (mounted) {
          setLoadError(errorMessage(error, 'Не удалось прочитать сохраненную сессию.'));
        }
        return null;
      })
      .then((storedSession) => {
        if (!storedSession) {
          return null;
        }
        if (mounted) {
          setLoadError(null);
          setSession(storedSession);
        }
        void refreshApiSession(storedSession.accessToken)
          .then(async (refreshedSession) => {
            await saveSession(refreshedSession);
            if (mounted) {
              setSession(refreshedSession);
            }
          })
          .catch(() => undefined);
        return storedSession;
      })
      .then((storedSession) => {
        if (mounted && !storedSession) {
          setSession(storedSession);
        }
      })
      .finally(() => {
        if (mounted) {
          setIsLoading(false);
        }
      });

    return () => {
      mounted = false;
    };
  }, []);

  const signIn = useCallback(async (nextSession: AuthSession) => {
    const sessionLoadError = loadError;
    clearClientData();
    await saveSession(nextSession);
    setLoadError(null);
    setSession(nextSession);
    if (sessionLoadError) {
      void uploadClientDiagnostics(
        nextSession.accessToken,
        sessionLoadFailureDiagnosticsSnapshot(sessionLoadError),
      ).catch(() => undefined);
    }
  }, [clearClientData, loadError]);

  const signOut = useCallback(async () => {
    await applySignOutState();
  }, [applySignOutState]);

  const refreshSession = useCallback(async () => {
    if (!session?.accessToken) {
      return null;
    }
    const refreshedSession = await refreshApiSession(session.accessToken);
    await saveSession(refreshedSession);
    setSession(refreshedSession);
    return refreshedSession;
  }, [session]);

  const value = useMemo(
    () => ({
      isLoading,
      loadError,
      session,
      signIn,
      signOut,
      refreshSession,
    }),
    [isLoading, loadError, refreshSession, session, signIn, signOut],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

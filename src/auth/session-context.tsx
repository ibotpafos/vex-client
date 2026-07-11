import React, { createContext, use, useCallback, useEffect, useMemo, useRef, useState, type PropsWithChildren } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { clearSession, loadSession, saveSession } from '@/auth/sessionStore';
import { loadSessionWithRetry } from '@/auth/sessionLoadRetry';
import { sessionLoadFailureDiagnosticsSnapshot } from '@/auth/sessionDiagnostics';
import { isCurrentSessionMutation } from '@/auth/sessionMutationGuard';
import { refreshSession as refreshApiSession, reportAppInstall, type AuthSession } from '@/api/vexApi';
import { ApiRequestError } from '@/api/error';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { errorMessage } from '@/utils/error';
import { disconnectVpn } from '@/native/vexVpn';

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
  const sessionRef = useRef<AuthSession | null>(null);
  const sessionRevisionRef = useRef(0);
  const refreshInFlightRef = useRef<Promise<AuthSession | null> | null>(null);
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
    sessionRevisionRef.current += 1;
    let storageError: unknown;
    await clearSession().catch((error) => {
      storageError = error;
    });
    // Do not hide a failed native teardown behind a successful-looking logout.
    // Keeping the authenticated screen mounted lets the user retry while the
    // disconnect watchdog performs its Android recovery path.
    await disconnectVpn({ releaseAntiLeak: true });
    sessionRef.current = null;
    clearClientData();
    setSession(null);
    setIsLoading(false);
    if (storageError) {
      throw storageError;
    }
  }, [clearClientData]);

  useEffect(() => {
    let mounted = true;
    const restoreRevision = sessionRevisionRef.current;
    const restoreSession = async () => {
      let storedSession: AuthSession | null = null;
      try {
        storedSession = await loadSessionWithRetry(loadSession);
      } catch (error) {
        if (mounted) {
          setLoadError(errorMessage(error, 'Не удалось прочитать сохраненную сессию.'));
        }
      }

      if (restoreRevision !== sessionRevisionRef.current) {
        return;
      }

      if (!storedSession) {
        if (mounted) {
          sessionRef.current = null;
          setSession(null);
          setIsLoading(false);
        }
        return;
      }

      // Do not expose the stored token to queries/connect until its rotating
      // refresh completes. The backend revokes that token as part of refresh.
      let restoredSession: AuthSession | null = storedSession;
      try {
        restoredSession = await refreshApiSession(storedSession.accessToken);
        if (restoreRevision !== sessionRevisionRef.current) {
          return;
        }
        await saveSession(restoredSession);
      } catch (error) {
        if (restoreRevision !== sessionRevisionRef.current) {
          return;
        }
        if (error instanceof ApiRequestError && error.status === 401) {
          await clearSession();
          restoredSession = null;
        }
        // Offline startup can still use the stored session and cached profile;
        // a definitively rejected token is cleared so the login screen opens.
      }

      if (mounted && restoreRevision === sessionRevisionRef.current) {
        sessionRef.current = restoredSession;
        setLoadError(null);
        setSession(restoredSession);
        setIsLoading(false);
      }
    };

    void restoreSession();

    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (!session?.accessToken || !session.user.id) {
      return;
    }
    void reportAppInstall(session.accessToken, session.user.id).catch(() => undefined);
  }, [session?.accessToken, session?.user.id]);

  const signIn = useCallback(async (nextSession: AuthSession) => {
    const sessionLoadError = loadError;
    sessionRevisionRef.current += 1;
    clearClientData();
    await saveSession(nextSession);
    sessionRef.current = nextSession;
    setLoadError(null);
    setSession(nextSession);
    setIsLoading(false);
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
    if (refreshInFlightRef.current) {
      return refreshInFlightRef.current;
    }
    const currentSession = sessionRef.current;
    if (!currentSession?.accessToken) {
      return null;
    }
    const refreshRevision = sessionRevisionRef.current;
    const refreshOperation = (async () => {
      const refreshedSession = await refreshApiSession(currentSession.accessToken);
      if (!isCurrentSessionMutation(
        refreshRevision,
        sessionRevisionRef.current,
        currentSession.accessToken,
        sessionRef.current?.accessToken,
      )) {
        return sessionRef.current;
      }
      await saveSession(refreshedSession);
      sessionRef.current = refreshedSession;
      setSession(refreshedSession);
      return refreshedSession;
    })();
    refreshInFlightRef.current = refreshOperation;
    try {
      return await refreshOperation;
    } finally {
      if (refreshInFlightRef.current === refreshOperation) {
        refreshInFlightRef.current = null;
      }
    }
  }, []);

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

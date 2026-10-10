import { createContext, use, useCallback, useEffect, useMemo, useRef, useState, type PropsWithChildren } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { clearSession, loadSession, saveSession } from '@/auth/sessionStore';
import { loadSessionWithRetry } from '@/auth/sessionLoadRetry';
import { sessionLoadFailureDiagnosticsSnapshot } from '@/auth/sessionDiagnostics';
import { isCurrentSessionMutation } from '@/auth/sessionMutationGuard';
import { isCurrentSessionOperation } from '@/auth/sessionOperationGuard';
import { createSessionMutationQueue } from '@/auth/sessionStoreCore';
import { refreshSession as refreshApiSession, reportAppInstall, type AuthSession } from '@/api/vexApi';
import { ApiRequestError } from '@/api/error';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { errorMessage } from '@/utils/error';
import { clearGoogleCredentialState } from '@/native/googleAuth';
import { disconnectVpn } from '@/native/vexVpn';

type SessionContextValue = {
  isLoading: boolean;
  loadError: string | null;
  session: AuthSession | null;
  isCurrentSessionOperation: () => boolean;
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
  const [sessionOperationRevision, setSessionOperationRevision] = useState(0);
  const sessionOperationsBlockedRef = useRef(false);
  const sessionTransitionsRef = useRef(createSessionMutationQueue());
  const runSessionTransition = sessionTransitionsRef.current;
  const refreshInFlightRef = useRef<Promise<AuthSession | null> | null>(null);
  // Bind callbacks to this login, while allowing its access token to rotate.
  // The ref changes before logout's first await, so retained VPN callbacks
  // cannot start a tunnel while storage cleanup or native teardown is pending.
  const sessionOperationIsCurrent = useCallback(() => isCurrentSessionOperation(
    sessionOperationRevision,
    sessionRevisionRef.current,
    session?.user.id,
    sessionRef.current?.user.id,
    sessionOperationsBlockedRef.current,
  ), [sessionOperationRevision, session?.user.id]);
  const clearClientData = useCallback(() => {
    queryClient.removeQueries({ queryKey: ['entitlement'] });
    queryClient.removeQueries({ queryKey: ['vpn-profile'] });
    queryClient.removeQueries({ queryKey: ['vpn-locations'] });
    queryClient.removeQueries({ queryKey: ['vpn-devices'] });
    queryClient.removeQueries({ queryKey: ['billing-summary'] });
    queryClient.removeQueries({ queryKey: ['android-update'] });
    queryClient.removeQueries({ queryKey: ['ios-update'] });
  }, [queryClient]);

  const applySignOutState = useCallback(async () => {
    sessionRevisionRef.current += 1;
    const signOutRevision = sessionRevisionRef.current;
    refreshInFlightRef.current = null;
    setSessionOperationRevision(sessionRevisionRef.current);
    sessionOperationsBlockedRef.current = true;
    try {
      await runSessionTransition(async () => {
        let storageError: unknown;
        await clearSession().catch((error) => {
          storageError = error;
        });
        // A new login waits for this teardown before exposing its session.
        // Failed teardown keeps the authenticated screen available for retry.
        await disconnectVpn({ releaseAntiLeak: true });
        sessionRef.current = null;
        if (signOutRevision !== sessionRevisionRef.current) return;
        clearClientData();
        setSession(null);
        setIsLoading(false);
        if (storageError) throw storageError;
      });
    } finally {
      if (signOutRevision === sessionRevisionRef.current) sessionOperationsBlockedRef.current = false;
    }
  }, [clearClientData, runSessionTransition]);

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
        await runSessionTransition(async () => {
          if (restoreRevision !== sessionRevisionRef.current) return;
          await saveSession(restoredSession!);
        });
        if (restoreRevision !== sessionRevisionRef.current) return;
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
  }, [runSessionTransition]);

  useEffect(() => {
    if (!session?.accessToken || !session.user.id) {
      return;
    }
    void reportAppInstall(session.accessToken, session.user.id).catch(() => undefined);
  }, [session?.accessToken, session?.user.id]);

  const signIn = useCallback(async (nextSession: AuthSession) => {
    const sessionLoadError = loadError;
    sessionRevisionRef.current += 1;
    const signInRevision = sessionRevisionRef.current;
    refreshInFlightRef.current = null;
    setSessionOperationRevision(sessionRevisionRef.current);
    sessionOperationsBlockedRef.current = true;
    clearClientData();
    try {
      await runSessionTransition(async () => {
        if (signInRevision !== sessionRevisionRef.current) return;
        if (sessionRef.current?.user.id && sessionRef.current.user.id !== nextSession.user.id) {
          await disconnectVpn({ releaseAntiLeak: true });
          if (signInRevision !== sessionRevisionRef.current) return;
        }
        await saveSession(nextSession);
        if (signInRevision !== sessionRevisionRef.current) return;
        sessionRef.current = nextSession;
        setLoadError(null);
        setSession(nextSession);
        setIsLoading(false);
      });
    } finally {
      if (signInRevision === sessionRevisionRef.current) sessionOperationsBlockedRef.current = false;
    }
    if (sessionLoadError) {
      void uploadClientDiagnostics(
        nextSession.accessToken,
        sessionLoadFailureDiagnosticsSnapshot(sessionLoadError),
      ).catch(() => undefined);
    }
  }, [clearClientData, loadError, runSessionTransition]);

  const signOut = useCallback(async () => {
    await applySignOutState();
    await clearGoogleCredentialState().catch(() => undefined);
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
      return runSessionTransition(async () => {
        if (!isCurrentSessionMutation(
          refreshRevision,
          sessionRevisionRef.current,
          currentSession.accessToken,
          sessionRef.current?.accessToken,
        )) {
          return sessionRef.current;
        }
        await saveSession(refreshedSession);
        if (!isCurrentSessionMutation(
          refreshRevision,
          sessionRevisionRef.current,
          currentSession.accessToken,
          sessionRef.current?.accessToken,
        )) {
          return sessionRef.current;
        }
        sessionRef.current = refreshedSession;
        setSession(refreshedSession);
        return refreshedSession;
      });
    })();
    refreshInFlightRef.current = refreshOperation;
    try {
      return await refreshOperation;
    } finally {
      if (refreshInFlightRef.current === refreshOperation) {
        refreshInFlightRef.current = null;
      }
    }
  }, [runSessionTransition]);

  const value = useMemo(
    () => ({
      isLoading,
      loadError,
      session,
      isCurrentSessionOperation: sessionOperationIsCurrent,
      signIn,
      signOut,
      refreshSession,
    }),
    [isLoading, loadError, refreshSession, session, sessionOperationIsCurrent, signIn, signOut],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

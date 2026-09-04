import { useQueryClient } from '@tanstack/react-query';
import { createContext, use, useEffect, useMemo, useState, type PropsWithChildren } from 'react';
import { AppState, type AppStateStatus } from 'react-native';

import { vexApiBaseUrl } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import {
  customerRealtimeDomains,
  customerRealtimeInvalidationRoots,
  customerRealtimeMetadata,
} from './customerRealtimeCore';
import { CustomerRealtimeTransport } from './customerRealtimeTransport';

type CustomerRealtimeContextValue = {
  connected: boolean;
  revision: number;
};

const CustomerRealtimeContext = createContext<CustomerRealtimeContextValue | null>(null);

export function useCustomerRealtimeStatus(): CustomerRealtimeContextValue {
  const value = use(CustomerRealtimeContext);
  if (!value) throw new Error('useCustomerRealtimeStatus must be wrapped in CustomerRealtimeProvider');
  return value;
}

export function CustomerRealtimeProvider({ children }: PropsWithChildren) {
  const queryClient = useQueryClient();
  const { refreshSession, session, signOut } = useSession();
  const [appState, setAppState] = useState<AppStateStatus>(AppState.currentState);
  const [connected, setConnected] = useState(false);
  const [revision, setRevision] = useState(0);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', setAppState);
    return () => subscription.remove();
  }, []);

  useEffect(() => {
    const accessToken = session?.accessToken;
    if (!accessToken || appState !== 'active') {
      setConnected(false);
      return;
    }
    const transport = new CustomerRealtimeTransport({
      accessToken,
      baseUrl: vexApiBaseUrl,
      onStatus: setConnected,
      onSessionRevoked: () => {
        void refreshSession().catch(() => signOut()).catch(() => undefined);
      },
      onEvent: (event) => {
        const metadata = customerRealtimeMetadata(event.type, event.data);
        if (!metadata || event.type === 'customer.heartbeat' || event.type === 'customer.session.revoked') return;
        const domains = event.type === 'customer.resync' && metadata.domains.length === 0
          ? customerRealtimeDomains
          : metadata.domains;
        for (const root of customerRealtimeInvalidationRoots(domains)) {
          void queryClient.invalidateQueries({ queryKey: [root] });
        }
        // Data resync is not credential expiry: rotating here revokes tokens
        // used by in-flight VPN requests and reconnects SSE into another resync.
        setRevision((current) => current + 1);
      },
    });
    transport.start();
    return () => transport.stop();
  }, [appState, queryClient, refreshSession, session?.accessToken, signOut]);

  const value = useMemo(() => ({ connected, revision }), [connected, revision]);
  return <CustomerRealtimeContext.Provider value={value}>{children}</CustomerRealtimeContext.Provider>;
}

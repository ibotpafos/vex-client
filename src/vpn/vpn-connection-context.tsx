import React, { createContext } from 'react';

import { useVpnConnection } from '@/vpn/useVpnConnection';

type VpnConnectionValue = ReturnType<typeof useVpnConnection>;

const VpnConnectionContext = createContext<VpnConnectionValue | null>(null);

export function VpnConnectionProvider({ children }: React.PropsWithChildren) {
  const value = useVpnConnection();
  return (
    <VpnConnectionContext.Provider value={value}>
      {children}
    </VpnConnectionContext.Provider>
  );
}

export function useVpnConnectionContext() {
  const value = React.use(VpnConnectionContext);
  if (!value) {
    throw new Error('useVpnConnectionContext must be used inside VpnConnectionProvider');
  }
  return value;
}

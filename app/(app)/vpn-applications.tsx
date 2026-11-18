import React, { Suspense } from 'react';

const VpnApplicationsScreen = React.lazy(() => import('../../src/screens/vpn-applications-screen').then((mod) => ({
  default: mod.VpnApplicationsScreen,
})));

export default function VpnApplicationsRoute() {
  return (
    <Suspense fallback={null}>
      <VpnApplicationsScreen />
    </Suspense>
  );
}

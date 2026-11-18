import React, { Suspense } from 'react';

const SettingsScreen = React.lazy(() => import('../../src/screens/settings-screen').then((mod) => ({
  default: mod.SettingsScreen,
})));

export default function SettingsRoute() {
  return (
    <Suspense fallback={null}>
      <SettingsScreen />
    </Suspense>
  );
}

import React, { Suspense } from 'react';

const UpdateCenterScreen = React.lazy(() => import('../../src/screens/update-center-screen').then((mod) => ({
  default: mod.UpdateCenterScreen,
})));

export default function UpdateCenterRoute() {
  return (
    <Suspense fallback={null}>
      <UpdateCenterScreen />
    </Suspense>
  );
}

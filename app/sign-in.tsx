import React, { Suspense } from 'react';

const SignInScreen = React.lazy(() => import('../src/screens/sign-in-screen').then((mod) => ({
  default: mod.SignInScreen,
})));

export default function SignInRoute() {
  return (
    <Suspense fallback={null}>
      <SignInScreen />
    </Suspense>
  );
}

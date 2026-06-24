import { Redirect, router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Platform } from 'react-native';

import { MobileUpdateCenterRouteContent } from '@/components/update-center';

const HOME_ROUTE = '/(app)/(tabs)/index';

function closeUpdateCenterRoute() {
  if (router.canGoBack()) {
    router.back();
    return;
  }
  router.replace(HOME_ROUTE);
}

export default function UpdateCenterScreen() {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return <Redirect href={HOME_ROUTE} />;
  }

  return (
    <>
      <StatusBar style="light" />
      <MobileUpdateCenterRouteContent
        onClose={closeUpdateCenterRoute}
        platform={Platform.OS}
      />
    </>
  );
}

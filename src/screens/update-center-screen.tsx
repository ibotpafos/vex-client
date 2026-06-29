import { Redirect, router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Platform } from 'react-native';

import { MobileUpdateCenterRouteContent } from '@/components/update-center';
import { HOME_TAB_ROUTE } from '@/navigation/routes';

const HOME_ROUTE = HOME_TAB_ROUTE;

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

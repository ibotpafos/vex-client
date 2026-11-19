import { Redirect } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Platform } from 'react-native';

import { MobileUpdateCenterRouteContent } from '@/components/update-center';
import { HOME_TAB_ROUTE, goBackOrHome } from '@/navigation/routes';

export default function UpdateCenterScreen() {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return <Redirect href={HOME_TAB_ROUTE} />;
  }

  return (
    <>
      <StatusBar style="light" />
      <MobileUpdateCenterRouteContent
        onClose={goBackOrHome}
        platform={Platform.OS}
      />
    </>
  );
}

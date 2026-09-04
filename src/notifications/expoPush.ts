import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

import { getFirebaseMessagingToken } from '@/native/vexVpn';
import { fcmPushRegistration, type FcmPushRegistration } from '@/notifications/pushRegistration';

const androidAccountEventsChannelId = 'vex_updates';

export async function getFcmAccountPushRegistration(allowPermissionPrompt = true): Promise<FcmPushRegistration | null> {
  if (Platform.OS === 'web') {
    return null;
  }

  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync(androidAccountEventsChannelId, {
      importance: Notifications.AndroidImportance.DEFAULT,
      name: 'VEX account events',
    });
  }

  const permission = await ensureNotificationPermission(allowPermissionPrompt);
  if (!permission) {
    return null;
  }

  return fcmPushRegistration(await getFirebaseMessagingToken());
}

async function ensureNotificationPermission(allowPermissionPrompt: boolean): Promise<boolean> {
  const current = await Notifications.getPermissionsAsync();
  if (current.granted) {
    return true;
  }

  if (!allowPermissionPrompt || !current.canAskAgain) return false;
  const requested = await Notifications.requestPermissionsAsync();
  return requested.granted;
}

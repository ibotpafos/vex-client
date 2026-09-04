import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

import { getFirebaseMessagingToken } from '@/native/vexVpn';
import { fcmPushRegistration, type FcmPushRegistration } from '@/notifications/pushRegistration';
import { createNotificationPermissionGate } from '@/notifications/notificationPermission';

const androidAccountEventsChannelId = 'vex_updates';
const ensureNotificationPermission = createNotificationPermissionGate({
  get: () => Notifications.getPermissionsAsync(),
  request: () => Notifications.requestPermissionsAsync(),
});

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

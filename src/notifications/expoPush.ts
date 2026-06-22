import Constants from 'expo-constants';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

const androidAccountEventsChannelId = 'vex_updates';

export type ExpoPushRegistration = {
  provider: 'expo';
  token: string;
};

export async function getExpoAccountPushRegistration(): Promise<ExpoPushRegistration | null> {
  if (Platform.OS === 'web') {
    return null;
  }

  const projectId = resolveProjectId();
  if (!projectId) {
    return null;
  }

  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync(androidAccountEventsChannelId, {
      importance: Notifications.AndroidImportance.DEFAULT,
      name: 'VEX account events',
    });
  }

  const permission = await ensureNotificationPermission();
  if (!permission) {
    return null;
  }

  const token = await Notifications.getExpoPushTokenAsync({ projectId });
  return { provider: 'expo', token: token.data };
}

async function ensureNotificationPermission(): Promise<boolean> {
  const current = await Notifications.getPermissionsAsync();
  if (current.granted) {
    return true;
  }

  const requested = await Notifications.requestPermissionsAsync();
  return requested.granted;
}

function resolveProjectId(): string {
  const constants = Constants as typeof Constants & {
    easConfig?: { projectId?: string };
  };
  return constants.easConfig?.projectId || Constants.expoConfig?.extra?.eas?.projectId || '';
}

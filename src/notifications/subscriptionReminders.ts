import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';
import { buildSubscriptionReminders } from './subscriptionReminderSchedule';

const reminderKind = 'subscription-expiry';
const androidChannelId = 'subscription_reminders';
export async function syncSubscriptionReminders(expiresAt?: string): Promise<boolean> {
  if (Platform.OS === 'web') return false;
  await cancelSubscriptionReminders();
  if (!expiresAt) return false;

  const permission = await Notifications.getPermissionsAsync();
  if (!permission.granted) return false;
  await ensureAndroidChannel();
  await Promise.all(buildSubscriptionReminders(expiresAt).map((reminder) =>
    Notifications.scheduleNotificationAsync({
      content: {
        title: reminder.daysBefore === 0 ? 'Подписка VEX заканчивается сегодня' : 'Скоро закончится подписка VEX',
        body: reminder.daysBefore === 0
          ? 'Продлите подписку, чтобы VPN продолжил работать без перерыва.'
          : `До окончания подписки ${daysText(reminder.daysBefore)}. Продлить можно в приложении.`,
        data: { kind: reminderKind, route: '/(app)/(tabs)/account' },
        sound: 'default',
      },
      trigger: {
        type: Notifications.SchedulableTriggerInputTypes.DATE,
        date: reminder.date,
        channelId: Platform.OS === 'android' ? androidChannelId : undefined,
      },
    }),
  ));
  return true;
}

export async function enableSubscriptionReminders(expiresAt?: string): Promise<boolean> {
  if (Platform.OS === 'web' || !expiresAt) return false;
  const permission = await Notifications.requestPermissionsAsync();
  if (!permission.granted) return false;
  return syncSubscriptionReminders(expiresAt);
}

async function cancelSubscriptionReminders() {
  const scheduled = await Notifications.getAllScheduledNotificationsAsync();
  await Promise.all(scheduled
    .filter((item) => item.content.data?.kind === reminderKind)
    .map((item) => Notifications.cancelScheduledNotificationAsync(item.identifier)));
}

async function ensureAndroidChannel() {
  if (Platform.OS !== 'android') return;
  await Notifications.setNotificationChannelAsync(androidChannelId, {
    importance: Notifications.AndroidImportance.DEFAULT,
    name: 'Напоминания о подписке',
  });
}

function daysText(days: number) {
  if (days === 1) return '1 день';
  if (days >= 2 && days <= 4) return `${days} дня`;
  return `${days} дней`;
}

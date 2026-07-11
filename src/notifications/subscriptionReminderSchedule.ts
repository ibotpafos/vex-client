export type SubscriptionReminder = {
  daysBefore: number;
  date: Date;
};

const reminderOffsets = [7, 3, 1, 0] as const;

export function buildSubscriptionReminders(expiresAt: string, now = new Date()): SubscriptionReminder[] {
  const expiry = new Date(expiresAt);
  if (Number.isNaN(expiry.getTime())) return [];

  return reminderOffsets.flatMap((daysBefore) => {
    const date = new Date(expiry);
    date.setDate(date.getDate() - daysBefore);
    date.setHours(daysBefore === 0 ? 9 : 11, 0, 0, 0);
    return date.getTime() > now.getTime() ? [{ daysBefore, date }] : [];
  });
}

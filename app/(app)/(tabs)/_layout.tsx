import { NativeTabs } from 'expo-router/unstable-native-tabs';

import { vexTheme } from '@/ui/vex-theme';

export default function AppTabsLayout() {
  return (
    <NativeTabs
      backBehavior="history"
      backgroundColor={vexTheme.colors.backgroundRaised}
      badgeBackgroundColor={vexTheme.colors.accent}
      badgeTextColor={vexTheme.colors.accentInk}
      iconColor={{ default: vexTheme.colors.textMuted, selected: vexTheme.colors.accentInk }}
      indicatorColor={vexTheme.colors.accent}
      labelVisibilityMode="labeled"
      labelStyle={{
        default: {
          color: vexTheme.colors.textMuted,
          fontSize: 12,
          fontWeight: '800',
        },
        selected: {
          color: vexTheme.colors.text,
          fontSize: 12,
          fontWeight: '900',
        },
      }}
    >
      <NativeTabs.Trigger name="index">
        <NativeTabs.Trigger.Icon md="home" sf="house.fill" />
        <NativeTabs.Trigger.Label>Главная</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="account">
        <NativeTabs.Trigger.Icon md="account_circle" sf="person.crop.circle.fill" />
        <NativeTabs.Trigger.Label>Аккаунт</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="support">
        <NativeTabs.Trigger.Icon md="chat_bubble" sf="questionmark.bubble.fill" />
        <NativeTabs.Trigger.Label>Поддержка</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}

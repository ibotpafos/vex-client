import { router } from 'expo-router';
import { NativeTabs } from 'expo-router/unstable-native-tabs';

export default function AppTabsLayout() {
  return (
    <NativeTabs
      backgroundColor="#071113"
      badgeBackgroundColor="#22D3EE"
      badgeTextColor="#031012"
      iconColor={{ default: 'rgba(167,185,189,0.8)', selected: '#031012' }}
      indicatorColor="#22D3EE"
      labelVisibilityMode="labeled"
      screenListeners={({ route }) => ({
        tabPress: () => {
          if (route.name !== 'support') {
            return;
          }
          router.push('/(app)/support-chat');
        },
      })}
      labelStyle={{
        default: {
          color: 'rgba(167,185,189,0.8)',
          fontSize: 11,
          fontWeight: '800',
        },
        selected: {
          color: '#031012',
          fontSize: 11,
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

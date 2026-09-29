import { Stack } from 'expo-router';
import { Platform } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';
import { stackAnimationForPlatform } from '@/navigation/transitionPolicy';

export const unstable_settings = {
  anchor: '(tabs)',
};

export default function AppLayout() {
  return (
      <Stack screenOptions={{ animation: stackAnimationForPlatform(Platform.OS) }}>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="settings" options={{ headerShown: false }} />
        <Stack.Screen name="vpn-applications" options={{ headerShown: false }} />
        <Stack.Screen
          name="server-picker"
          options={{
            contentStyle: { backgroundColor: vexTheme.colors.background },
            headerShown: false,
            presentation: Platform.OS === 'ios' ? 'formSheet' : 'modal',
            ...(Platform.OS === 'ios'
              ? {
                  sheetAllowedDetents: [0.74, 1],
                  sheetCornerRadius: 24,
                  sheetGrabberVisible: true,
                  sheetInitialDetentIndex: 0,
                }
              : null),
          }}
        />
        <Stack.Screen
          name="update-center"
          options={{
            contentStyle: { backgroundColor: vexTheme.colors.background },
            headerShown: false,
            presentation: Platform.OS === 'ios' ? 'formSheet' : 'modal',
            ...(Platform.OS === 'ios'
              ? {
                  sheetAllowedDetents: [0.64, 1],
                  sheetCornerRadius: 24,
                  sheetGrabberVisible: true,
                  sheetInitialDetentIndex: 0,
                }
              : null),
          }}
        />
      </Stack>
  );
}

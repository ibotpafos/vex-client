import { Stack } from 'expo-router';
import { Platform } from 'react-native';
import { VpnConnectionProvider } from '@/vpn/vpn-connection-context';

export const unstable_settings = {
  anchor: '(tabs)',
};

export default function AppLayout() {
  return (
    <VpnConnectionProvider>
      <Stack>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="settings" options={{ headerShown: false }} />
        <Stack.Screen name="support-chat" options={{ headerShown: false }} />
        <Stack.Screen
          name="server-picker"
          options={{
            contentStyle: { backgroundColor: '#071113' },
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
            contentStyle: { backgroundColor: '#071113' },
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
        <Stack.Screen
          name="subscription"
          options={{
            contentStyle: { backgroundColor: Platform.OS === 'ios' ? 'transparent' : '#071113' },
            headerShown: false,
            presentation: Platform.OS === 'ios' ? 'formSheet' : 'modal',
            ...(Platform.OS === 'ios'
              ? {
                  sheetAllowedDetents: [0.44, 0.64],
                  sheetCornerRadius: 24,
                  sheetGrabberVisible: true,
                  sheetInitialDetentIndex: 0,
                  sheetLargestUndimmedDetentIndex: 0,
                }
              : null),
          }}
        />
      </Stack>
    </VpnConnectionProvider>
  );
}

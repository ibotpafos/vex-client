import { Stack } from 'expo-router';
import { Platform } from 'react-native';

export const unstable_settings = {
  anchor: 'index',
};

export default function AppLayout() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ headerShown: false }} />
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
      <Stack.Screen name="settings" options={{ headerShown: false }} />
    </Stack>
  );
}

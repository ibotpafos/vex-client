import { Stack } from 'expo-router';

export default function AppTabsLayout() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ headerShown: false }} />
      <Stack.Screen name="account" options={{ headerShown: false }} />
      <Stack.Screen name="support" options={{ headerShown: false }} />
    </Stack>
  );
}

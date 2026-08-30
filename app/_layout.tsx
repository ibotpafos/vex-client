import '@/native/cryptoPolyfill';

import { QueryClient, QueryClientProvider, focusManager } from '@tanstack/react-query';
import { Button, Column, Host, Spacer, Text as UniversalText } from '@expo/ui';
import * as Notifications from 'expo-notifications';
import { Stack, type ErrorBoundaryProps } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { AppState, Platform, StyleSheet, View, type AppStateStatus } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { SessionProvider, useSession } from '@/auth/session-context';
import { openExternalUrl } from '@/auth/systemAuth';
import { SplashScreenController } from '@/auth/splash-screen-controller';
import { vexWebsite } from '@/navigation/website';
import { AndroidUpdateOverlay } from '@/components/android-update-overlay';
import { IOSUpdateOverlay } from '@/components/ios-update-overlay';
import { OtaUpdateOverlay } from '@/components/ota-update-overlay';
import { RenderProfilerOverlay } from '@/debug/render-profiler';
import { captureError, initSentry } from '@/observability/sentry';
import { ToastProvider } from '@/ui/toast';
import { VpnConnectionProvider } from '@/vpn/vpn-connection-context';
import { CustomerRealtimeProvider } from '@/realtime/customer-realtime-context';

initSentry();

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldPlaySound: true,
    shouldSetBadge: false,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
});

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      gcTime: 30 * 60_000,
      refetchOnMount: false,
      refetchOnReconnect: true,
      refetchOnWindowFocus: false,
      staleTime: 5 * 60_000,
    },
  },
});

export default function RootLayout() {
  useEffect(() => {
    if (Platform.OS === 'web') {
      const style = document.createElement('style');
      style.textContent = `
        div[class*="navigationMenuRoot"] {
          top: auto !important;
          bottom: 20px !important;
          box-shadow: 0 8px 30px rgba(0, 0, 0, 0.6) !important;
          border: 1px solid rgba(34, 211, 238, 0.25) !important;
          background-color: rgba(7, 17, 19, 0.92) !important;
          backdrop-filter: blur(8px) !important;
        }
      `;
      document.head.appendChild(style);
      return () => {
        document.head.removeChild(style);
      };
    }
  }, []);

  return (
    <QueryClientProvider client={queryClient}>
      <ReactQueryAppStateBridge />
      <NotificationNavigationBridge />
      <SafeAreaProvider>
        <SessionProvider>
          <CustomerRealtimeProvider>
            <ToastProvider>
              <SplashScreenController />
              <RootNavigator />
            </ToastProvider>
          </CustomerRealtimeProvider>
        </SessionProvider>
      </SafeAreaProvider>
    </QueryClientProvider>
  );
}

function NotificationNavigationBridge() {
  useEffect(() => {
    if (Platform.OS === 'web') return;
    const openSubscription = (response: Notifications.NotificationResponse) => {
      if (response.notification.request.content.data?.kind === 'subscription-expiry') {
        void openExternalUrl(vexWebsite.dashboard()).catch(() => undefined);
      }
    };
    const subscription = Notifications.addNotificationResponseReceivedListener(openSubscription);
    void Notifications.getLastNotificationResponseAsync().then((response) => {
      if (response) openSubscription(response);
    });
    return () => subscription.remove();
  }, []);
  return null;
}

function ReactQueryAppStateBridge() {
  useEffect(() => {
    if (Platform.OS === 'web') {
      return;
    }

    const syncFocusState = (status: AppStateStatus) => {
      focusManager.setFocused(status === 'active');
    };

    syncFocusState(AppState.currentState);
    const subscription = AppState.addEventListener('change', syncFocusState);
    return () => subscription.remove();
  }, []);

  return null;
}

export function ErrorBoundary({ error, retry }: ErrorBoundaryProps) {
  useEffect(() => {
    captureError(error);
  }, [error]);

  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <Column alignment="center" spacing={14} style={styles.hostContent}>
        <Spacer flexible />
        <UniversalText textStyle={styles.errorTitle}>VEX</UniversalText>
        <UniversalText textStyle={styles.errorMessage}>Не удалось открыть приложение.</UniversalText>
        {__DEV__ ? <UniversalText textStyle={styles.errorDetails}>{error.message}</UniversalText> : null}
        <Button label="Повторить" onPress={retry} />
        <Spacer flexible />
      </Column>
    </Host>
  );
}

function RootNavigator() {
  const { isLoading, session } = useSession();

  if (isLoading) {
    return <BootScreen />;
  }

  const navigator = (
    <>
      {Platform.OS !== 'android' ? <StatusBar style="light" /> : null}
      <View style={styles.root}>
        <Stack>
          <Stack.Screen name="index" options={{ headerShown: false }} />
          <Stack.Screen name="auth/callback" options={{ headerShown: false }} />
          <Stack.Protected guard={Boolean(session)}>
            <Stack.Screen name="(app)" options={{ headerShown: false }} />
          </Stack.Protected>
          <Stack.Protected guard={!session}>
            <Stack.Screen name="sign-in" options={{ headerShown: false }} />
          </Stack.Protected>
        </Stack>
        <DeferredStartupOverlays />
        <RenderProfilerOverlay />
      </View>
    </>
  );

  return session
    ? <VpnConnectionProvider>{navigator}</VpnConnectionProvider>
    : navigator;
}

function BootScreen() {
  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <Column alignment="center" spacing={16} style={styles.hostContent}>
        <Spacer flexible />
        <UniversalText textStyle={styles.bootTitle}>VEX</UniversalText>
        <UniversalText textStyle={styles.bootMessage}>Готовим защищённое подключение…</UniversalText>
        <Spacer flexible />
      </Column>
    </Host>
  );
}

function DeferredStartupOverlays() {
  const [canMount, setCanMount] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => setCanMount(true), Platform.OS === 'android' ? 3500 : 1500);
    return () => clearTimeout(timer);
  }, []);

  if (!canMount) {
    return null;
  }

  return (
    <>
      <AndroidUpdateOverlay />
      <IOSUpdateOverlay />
      <OtaUpdateOverlay />
    </>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  host: {
    flex: 1,
  },
  hostContent: {
    backgroundColor: '#041315',
    flex: 1,
    gap: 16,
    paddingHorizontal: 32,
  },
  bootTitle: {
    color: '#43D9E7',
    fontSize: 34,
    fontWeight: '900',
  },
  bootMessage: {
    color: '#91A8AC',
    fontSize: 15,
    textAlign: 'center',
  },
  errorTitle: {
    color: '#F4FCFD',
    fontSize: 42,
    fontWeight: '900',
  },
  errorMessage: {
    color: '#DCECEE',
    fontSize: 18,
    fontWeight: '800',
    textAlign: 'center',
  },
  errorDetails: {
    color: '#9DB4B8',
    fontSize: 13,
    lineHeight: 18,
    maxWidth: 520,
    textAlign: 'center',
  },
});

import { QueryClient, QueryClientProvider, focusManager } from '@tanstack/react-query';
import { Stack, type ErrorBoundaryProps } from 'expo-router';
import { useEffect, useState } from 'react';
import { AppState, Image, Platform, Pressable, StyleSheet, Text, View, type AppStateStatus } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { SessionProvider, useSession } from '@/auth/session-context';
import { SplashScreenController } from '@/auth/splash-screen-controller';
import { DesktopUpdateProvider, DesktopUpdateOverlay } from '@/components/desktop-update-overlay';
import { AndroidUpdateOverlay } from '@/components/android-update-overlay';
import { IOSUpdateOverlay } from '@/components/ios-update-overlay';
import { OtaUpdateOverlay } from '@/components/ota-update-overlay';
import { RenderProfilerOverlay } from '@/debug/render-profiler';
import { captureError, initSentry } from '@/observability/sentry';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { ToastProvider } from '@/ui/toast';

initSentry();

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
      <SafeAreaProvider>
        <SessionProvider>
          <DesktopUpdateProvider>
            <ToastProvider>
              <SplashScreenController />
              <RootNavigator />
            </ToastProvider>
          </DesktopUpdateProvider>
        </SessionProvider>
      </SafeAreaProvider>
    </QueryClientProvider>
  );
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
    <View style={styles.errorScreen}>
      <Text style={styles.errorTitle}>VEX</Text>
      <Text style={styles.errorMessage}>Не удалось открыть приложение.</Text>
      {__DEV__ ? <Text selectable style={styles.errorDetails}>{error.message}</Text> : null}
      <Pressable accessibilityRole="button" onPress={retry} style={styles.retryButton}>
        <Text style={styles.retryButtonText}>Повторить</Text>
      </Pressable>
    </View>
  );
}

function RootNavigator() {
  const { isLoading, session } = useSession();

  if (isLoading) {
    return <BootScreen />;
  }

  return (
    <View style={styles.root}>
      <Stack>
        <Stack.Screen name="index" options={{ headerShown: false }} />
        <Stack.Screen name="auth/callback" options={{ headerShown: false }} />
        <Stack.Protected guard={Boolean(session)}>
          <Stack.Screen name="(app)" options={{ headerShown: false }} />
          <Stack.Screen name="billing/return" options={{ headerShown: false }} />
        </Stack.Protected>
        <Stack.Protected guard={!session}>
          <Stack.Screen name="sign-in" options={{ headerShown: false }} />
        </Stack.Protected>
      </Stack>
      <DeferredStartupOverlays />
      <RenderProfilerOverlay />
    </View>
  );
}

function BootScreen() {
  return (
    <View style={styles.bootScreen}>
      <Image
        accessibilityIgnoresInvertColors
        resizeMode="contain"
        source={require('../assets/splash-icon.png')}
        style={styles.bootLogo}
      />
      <Text style={styles.bootTitle}>VEX</Text>
      <VexNativeActivityIndicator color="#22D3EE" size="large" />
    </View>
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
      <DesktopUpdateOverlay />
    </>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  bootScreen: {
    alignItems: 'center',
    backgroundColor: '#020A0B',
    flex: 1,
    gap: 16,
    justifyContent: 'center',
    paddingHorizontal: 32,
  },
  bootLogo: {
    height: 176,
    width: 176,
  },
  bootTitle: {
    color: '#F4FCFD',
    fontSize: 34,
    fontWeight: '900',
  },
  errorScreen: {
    alignItems: 'center',
    backgroundColor: '#020A0B',
    flex: 1,
    gap: 14,
    justifyContent: 'center',
    paddingHorizontal: 24,
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
  retryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 8,
    minHeight: 48,
    justifyContent: 'center',
    marginTop: 6,
    paddingHorizontal: 22,
  },
  retryButtonText: {
    color: '#031012',
    fontSize: 16,
    fontWeight: '900',
  },
});

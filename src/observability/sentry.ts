import * as Sentry from '@sentry/react-native';
import * as Application from 'expo-application';
import { Platform } from 'react-native';

const dsn = process.env.EXPO_PUBLIC_SENTRY_DSN?.trim();

export function initSentry() {
  if (!dsn) {
    return;
  }

  const nativeApplicationVersion = Application.nativeApplicationVersion ?? 'unknown';
  const nativeBuildVersion = Application.nativeBuildVersion ?? 'unknown';

  Sentry.init({
    dsn,
    environment: process.env.EXPO_PUBLIC_SENTRY_ENVIRONMENT,
    release: process.env.EXPO_PUBLIC_SENTRY_RELEASE?.trim()
      || `${Platform.OS === 'android' ? 'vex-android' : 'vex'}@${nativeApplicationVersion}+${nativeBuildVersion}`,
    dist: nativeBuildVersion,
    initialScope: {
      tags: {
        app_platform: Platform.OS,
        native_app_version: nativeApplicationVersion,
        native_build_version: nativeBuildVersion,
      },
    },
    sendDefaultPii: false,
    enableAutoSessionTracking: false,
    tracesSampleRate: 0,
  });
}

export function captureError(error: unknown) {
  if (!dsn) {
    return;
  }
  Sentry.captureException(error);
}

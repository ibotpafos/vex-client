import * as Sentry from '@sentry/react-native';

const dsn = process.env.EXPO_PUBLIC_SENTRY_DSN?.trim();

export function initSentry() {
  if (!dsn) {
    return;
  }

  Sentry.init({
    dsn,
    environment: process.env.EXPO_PUBLIC_SENTRY_ENVIRONMENT,
    release: process.env.EXPO_PUBLIC_SENTRY_RELEASE,
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

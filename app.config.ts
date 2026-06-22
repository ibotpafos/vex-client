import type { ConfigContext, ExpoConfig } from 'expo/config';

const baseConfig = require('./app.json') as { expo: ExpoConfig };

const defaultApiBaseUrl = 'https://vexguard.app';
const defaultUpdateChannel = 'production';

export default function appConfig({ config }: ConfigContext): ExpoConfig {
  const updateChannel = env('EXPO_PUBLIC_VEX_UPDATE_CHANNEL', env('EXPO_PUBLIC_VEX_RELEASE_CHANNEL', defaultUpdateChannel));
  const buildProfile = env('VEX_BUILD_PROFILE', updateChannel);

  return {
    ...config,
    ...baseConfig.expo,
    name: 'VEX',
    slug: 'vex-windows-client',
    scheme: 'vexguard',
    version: baseConfig.expo.version,
    updates: {
      enabled: false,
      checkAutomatically: 'ON_LOAD',
      fallbackToCacheTimeout: 0,
    },
    extra: {
      ...baseConfig.expo.extra,
      eas: undefined,
      vex: {
        apiBaseUrl: env('EXPO_PUBLIC_VEX_API_BASE_URL', defaultApiBaseUrl),
        appVariant: buildProfile,
        billingFailedUrl: env('EXPO_PUBLIC_VEX_BILLING_FAILED_URL', `${defaultApiBaseUrl}/v1/billing/mobile-return?status=failed`),
        billingReturnUrl: env('EXPO_PUBLIC_VEX_BILLING_RETURN_URL', `${defaultApiBaseUrl}/v1/billing/mobile-return?status=success`),
        updateChannel,
      },
    },
    plugins: [
      'expo-secure-store',
      [
        'expo-local-authentication',
        {
          faceIDPermission: 'Разрешите VEX использовать биометрию для входа в приложение.',
        },
      ],
      [
        'expo-splash-screen',
        {
          backgroundColor: '#020A0B',
          image: './assets/splash-icon.png',
          imageWidth: 160,
          resizeMode: 'contain',
        },
      ],
      'expo-router',
    ],
  };
}

function env(name: string, fallback: string): string {
  return process.env[name]?.trim() || fallback;
}

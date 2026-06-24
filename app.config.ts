import type { ConfigContext, ExpoConfig } from 'expo/config';

const baseConfig = require('./app.json') as { expo: ExpoConfig };

const appName = 'VEX';
const appScheme = 'vexguard';
const appLinkHost = 'vexguard.app';
const androidPackage = env('VEX_ANDROID_APPLICATION_ID', 'com.vexguard.app');
const iosBundleIdentifier = 'com.vexguard.app';
const defaultApiBaseUrl = 'https://vexguard.app';
const defaultUpdateChannel = 'production';
const defaultRuntimeVersion = baseConfig.expo.version || '1.0.0';
const defaultProjectId = baseConfig.expo.extra?.eas?.projectId || '';
const defaultOtaUpdateUrl = 'https://updates.vexguard.app/manifest';
const defaultOtaCodeSigningCertificate = './certs/certificate.pem';

export default function appConfig({ config }: ConfigContext): ExpoConfig {
  const updateChannel = env('EXPO_PUBLIC_VEX_UPDATE_CHANNEL', env('EXPO_PUBLIC_VEX_RELEASE_CHANNEL', defaultUpdateChannel));
  const buildProfile = env('VEX_BUILD_PROFILE', updateChannel);
  const projectId = env('VEX_EAS_PROJECT_ID', env('EXPO_PUBLIC_EAS_PROJECT_ID', defaultProjectId));
  const updatesEnabled = Boolean(projectId) && env('VEX_UPDATES_ENABLED', buildProfile === 'production' ? '1' : '0') === '1';
  const updateUrl = resolveUpdateUrl();
  const codeSigningCertificate = env('VEX_OTA_CODE_SIGNING_CERTIFICATE', defaultOtaCodeSigningCertificate);
  const runtimeVersion = env('VEX_RUNTIME_VERSION', defaultRuntimeVersion);

  return {
    ...config,
    ...baseConfig.expo,
    name: appName,
    slug: 'vex',
    scheme: appScheme,
    version: baseConfig.expo.version,
    runtimeVersion,
    updates: {
      enabled: updatesEnabled,
      checkAutomatically: 'ON_LOAD',
      fallbackToCacheTimeout: 0,
      ...(updatesEnabled ? buildUpdatesConfig(updateUrl, updateChannel, codeSigningCertificate) : {}),
    },
    extra: {
      ...baseConfig.expo.extra,
      eas: projectId ? { projectId } : undefined,
      vex: {
        apiBaseUrl: env('EXPO_PUBLIC_VEX_API_BASE_URL', defaultApiBaseUrl),
        appVariant: buildProfile,
        billingFailedUrl: env('EXPO_PUBLIC_VEX_BILLING_FAILED_URL', `${defaultApiBaseUrl}/v1/billing/mobile-return?status=failed`),
        billingReturnUrl: env('EXPO_PUBLIC_VEX_BILLING_RETURN_URL', `${defaultApiBaseUrl}/v1/billing/mobile-return?status=success`),
        updateChannel,
      },
    },
    ios: {
      ...baseConfig.expo.ios,
      associatedDomains: [`applinks:${appLinkHost}`],
      bundleIdentifier: iosBundleIdentifier,
    },
    android: {
      ...baseConfig.expo.android,
      package: androidPackage,
      versionCode: baseConfig.expo.android?.versionCode,
      intentFilters: [
        {
          action: 'VIEW',
          autoVerify: false,
          data: [{ scheme: appScheme, host: 'auth', pathPrefix: '/callback' }],
          category: ['BROWSABLE', 'DEFAULT'],
        },
      ],
    },
    plugins: [
      'expo-secure-store',
      [
        'expo-local-authentication',
        {
          faceIDPermission: 'Разрешите VEX использовать Face ID для входа в приложение.',
        },
      ],
      [
        'expo-notifications',
        {
          defaultChannel: 'vex_updates',
        },
      ],
      [
        'expo-splash-screen',
        {
          backgroundColor: '#020A0B',
          image: './assets/splash-icon.png',
          imageWidth: 160,
          resizeMode: 'contain',
          android: {
            backgroundColor: '#020A0B',
            image: './assets/splash-icon.png',
            imageWidth: 160,
            resizeMode: 'contain',
          },
          ios: {
            backgroundColor: '#020A0B',
            image: './assets/splash-icon.png',
            imageWidth: 160,
            resizeMode: 'contain',
          },
        },
      ],
      [
        './modules/vex-vpn/plugin/withVexNativeConfig',
        {
          authScheme: appScheme,
          notificationChannelId: 'vex_updates',
        },
      ],
      './modules/vex-vpn/plugin/withVexVpnIos',
      'expo-router',
    ],
  };
}

function env(name: string, fallback: string): string {
  return process.env[name]?.trim() || fallback;
}

function resolveUpdateUrl(): string {
  const configuredUrl = process.env.VEX_OTA_UPDATE_URL?.trim();
  if (configuredUrl) {
    return configuredUrl;
  }

  return defaultOtaUpdateUrl;
}

function buildUpdatesConfig(updateUrl: string, channel: string, codeSigningCertificate: string): NonNullable<ExpoConfig['updates']> {
  const config: NonNullable<ExpoConfig['updates']> = {
    url: updateUrl,
    requestHeaders: {
      'expo-channel-name': channel,
    },
  };

  if (!updateUrl.includes('expo.dev') && codeSigningCertificate) {
    config.codeSigningCertificate = codeSigningCertificate;
    config.codeSigningMetadata = {
      keyid: 'main',
      alg: 'rsa-v1_5-sha256',
    };
  }

  return config;
}

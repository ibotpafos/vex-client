import * as Application from 'expo-application';
import { Platform } from 'react-native';
import * as SecureStore from '@/native/secureStore';

export type AppInfo = {
  name: string;
  version: string;
  build: string | null;
  platform: 'android' | 'ios' | 'windows' | 'macos' | 'linux' | 'web';
  channel: string;
  coreVersion: string;
  configSchemaVersion: number;
  apiClientVersion: string;
};

export const VEX_CONFIG_SCHEMA_VERSION = 1;
export const VEX_API_CLIENT_VERSION = "expo-1";
export const VEX_CORE_VERSION = "0.1.0";

function isTauri(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

export async function getAppInfo(): Promise<AppInfo> {
  if (isTauri()) {
    const [{ getName, getVersion }] = await Promise.all([
      import('@tauri-apps/api/app'),
    ]);
    return {
      name: await getName(),
      version: await getVersion(),
      build: null,
      platform: detectPlatform(),
      channel: currentChannel(),
      coreVersion: VEX_CORE_VERSION,
      configSchemaVersion: VEX_CONFIG_SCHEMA_VERSION,
      apiClientVersion: VEX_API_CLIENT_VERSION,
    };
  }

  return {
    name: Application.applicationName || 'VEX',
    version: Application.nativeApplicationVersion || 'dev',
    build: Application.nativeBuildVersion || '0',
    platform: detectPlatform(),
    channel: currentChannel(),
    coreVersion: VEX_CORE_VERSION,
    configSchemaVersion: VEX_CONFIG_SCHEMA_VERSION,
    apiClientVersion: VEX_API_CLIENT_VERSION,
  };
}

export async function getOrCreateDeviceId(): Promise<string> {
  const key = 'vex.auth.device_id';
  let deviceId = await SecureStore.getItemAsync(key).catch(() => null);
  if (!deviceId) {
    deviceId = `${detectPlatform()}-${Math.random().toString(36).slice(2, 12)}`;
    await SecureStore.setItemAsync(key, deviceId).catch(() => undefined);
  }
  return deviceId;
}

function currentChannel(): string {
  return process.env.EXPO_PUBLIC_VEX_UPDATE_CHANNEL || process.env.EXPO_PUBLIC_VEX_RELEASE_CHANNEL || 'production';
}

function detectPlatform(): AppInfo['platform'] {
  if (Platform.OS === 'android') return 'android';
  if (Platform.OS === 'ios') return 'ios';
  if (Platform.OS === 'web' && typeof navigator !== 'undefined') {
    const runtime = `${navigator.platform} ${navigator.userAgent}`.toLowerCase();
    if (runtime.includes('win')) return 'windows';
    if (runtime.includes('mac') || runtime.includes('darwin')) return 'macos';
    if (runtime.includes('linux') || runtime.includes('x11') || runtime.includes('wayland')) return 'linux';
  }
  return 'web';
}

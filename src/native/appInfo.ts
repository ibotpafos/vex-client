import * as Application from 'expo-application';
import { Platform } from 'react-native';
import { isTauriRuntime as isTauri } from './tauriPlatform';
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
    deviceId = `vexd_${createInstallationUUID()}`;
    await SecureStore.setItemAsync(key, deviceId).catch(() => undefined);
  }
  return deviceId;
}

export async function getOrCreateInstallId(): Promise<string> {
  const key = 'vex.app.install_id.v1';
  let installId = await SecureStore.getItemAsync(key).catch(() => null);
  if (!installId) {
    installId = `vexi_${createInstallationUUID()}`;
    await SecureStore.setItemAsync(key, installId).catch(() => undefined);
  }
  return installId;
}

function createInstallationUUID(): string {
  const runtimeCrypto = globalThis.crypto;
  if (typeof runtimeCrypto?.randomUUID === 'function') {
    return runtimeCrypto.randomUUID();
  }
  if (typeof runtimeCrypto?.getRandomValues !== 'function') {
    throw new Error('Secure random generator is unavailable.');
  }
  const bytes = new Uint8Array(16);
  runtimeCrypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
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

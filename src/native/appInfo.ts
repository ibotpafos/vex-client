import * as Application from 'expo-application';
import { Platform } from 'react-native';
import * as SecureStore from '@/native/secureStore';
import { getOtaProvenance } from '@/diagnostics/otaProvenance';

export type AppInfo = {
  name: string;
  version: string;
  build: string | null;
  platform: 'android' | 'ios' | 'web';
  channel: string;
  coreVersion: string;
  configSchemaVersion: number;
  apiClientVersion: string;
  otaRuntimeVersion: string | null;
  otaLaunch: 'unknown' | 'embedded' | 'applied' | 'emergency';
};

export const VEX_CONFIG_SCHEMA_VERSION = 1;
export const VEX_API_CLIENT_VERSION = "expo-1";
export const VEX_CORE_VERSION = "0.1.0";


export async function getAppInfo(): Promise<AppInfo> {
  const ota = getOtaProvenance();
  return {
    name: Application.applicationName || 'VEX',
    version: Application.nativeApplicationVersion || 'dev',
    build: Application.nativeBuildVersion || '0',
    platform: detectPlatform(),
    channel: currentChannel(),
    coreVersion: VEX_CORE_VERSION,
    configSchemaVersion: VEX_CONFIG_SCHEMA_VERSION,
    apiClientVersion: VEX_API_CLIENT_VERSION,
    otaRuntimeVersion: ota.ota_runtime_version ?? null,
    otaLaunch: ota.ota_is_emergency_launch ? 'emergency' : ota.ota_is_embedded_launch ? 'embedded' : ota.ota_update_id ? 'applied' : 'unknown',
  };
}

const installationIdentities = new Map<string, Promise<string>>();

export function getOrCreateDeviceId(): Promise<string> {
  return installationIdentity('vex.auth.device_id', 'vexd');
}

export function getOrCreateInstallId(): Promise<string> {
  return installationIdentity('vex.app.install_id.v1', 'vexi');
}

function installationIdentity(key: string, prefix: string): Promise<string> {
  const existing = installationIdentities.get(key);
  if (existing) return existing;
  const pending = (async () => {
    // A locked/unavailable store is not evidence of a new installation.
    const stored = await SecureStore.getItemAsync(key);
    if (stored) return stored;
    const value = `${prefix}_${createInstallationUUID()}`;
    await SecureStore.setItemAsync(key, value);
    return value;
  })().catch(error => {
    installationIdentities.delete(key);
    throw error;
  });
  installationIdentities.set(key, pending);
  return pending;
}

function createInstallationUUID(): string {
  const runtimeCrypto = globalThis.crypto;
  if (typeof runtimeCrypto?.randomUUID === 'function') {
    return runtimeCrypto.randomUUID();
  }
  if (typeof runtimeCrypto?.getRandomValues !== 'function') {
    throw new Error('Secure random generator is unavailable.');
  }
  const bytes = runtimeCrypto.getRandomValues(new Uint8Array(16));
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
  return 'web';
}

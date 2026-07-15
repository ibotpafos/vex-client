import { Platform } from 'react-native';
import * as SecureStore from '@/native/secureStore';
import { safeGetStoredValue } from '@/settings/safeStorage';
import { defaultVpnRoutingMode, isSmartRoutingMode, normalizeVpnRoutingMode, type VpnRoutingMode } from '@/vpn/routingPolicy';
import { normalizeServerSelectionMode, type ServerSelectionMode } from '@/vpn/serverSelection';
import { normalizePackageNames, type VpnApplicationRoutingMode } from '@/vpn/applicationRouting';
import { androidExperimentalRoutingEnabled } from '@/vpn/androidRoutingSafety';

export { normalizePackageNames, type VpnApplicationRoutingMode } from '@/vpn/applicationRouting';

const androidAutoConnectKey = 'vex.settings.android.autoconnect.v1';
const antiLeakEnabledKey = 'vex.settings.vpn.anti_leak.v1';
const smartRoutingEnabledKey = 'vex.settings.vpn.smart_routing.v1';
const routingModeKey = 'vex.settings.vpn.routing_mode.v1';
const serverSelectionModeKey = 'vex.settings.vpn.server_selection_mode.v1';
const selectedVpnLocationKey = 'vex.settings.vpn.location.v1';
const vpnApplicationRoutingModeKey = 'vex.settings.vpn.application_routing_mode.v1';
const selectedVpnApplicationsKey = 'vex.settings.vpn.selected_applications.v1';
const defaultVpnLocation = 'de';
const androidRoutingExperiment = androidExperimentalRoutingEnabled(
  Platform.OS,
  process.env.EXPO_PUBLIC_VEX_ANDROID_EXPERIMENTAL_ROUTING,
);

export type VpnApplicationSelection = {
  mode: VpnApplicationRoutingMode;
  packageNames: string[];
};

export function supportsAndroidAutoConnect(): boolean {
  return Platform.OS === 'android';
}

export async function getAndroidAutoConnectEnabled(): Promise<boolean> {
  if (!supportsAndroidAutoConnect()) {
    return false;
  }
  return (await safeGetSetting(androidAutoConnectKey)) === 'true';
}

export async function setAndroidAutoConnectEnabled(enabled: boolean): Promise<boolean> {
  if (!supportsAndroidAutoConnect()) {
    return false;
  }
  await SecureStore.setItemAsync(androidAutoConnectKey, enabled ? 'true' : 'false');
  return enabled;
}

export async function getAntiLeakEnabled(): Promise<boolean> {
  // The production build enables this gate after the Android 9/16 acceptance matrix.
  // Keeping the gate lets an emergency OTA force full-tunnel/no-blocker behavior.
  if (Platform.OS === 'android' && !androidRoutingExperiment) {
    return false;
  }
  return (await safeGetSetting(antiLeakEnabledKey)) !== 'false';
}

export async function setAntiLeakEnabled(enabled: boolean): Promise<boolean> {
  if (Platform.OS === 'android' && !androidRoutingExperiment) {
    await SecureStore.setItemAsync(antiLeakEnabledKey, 'false');
    return false;
  }
  await SecureStore.setItemAsync(antiLeakEnabledKey, enabled ? 'true' : 'false');
  return enabled;
}

export async function getVpnRoutingMode(): Promise<VpnRoutingMode> {
  if (Platform.OS === 'android' && !androidRoutingExperiment) {
    return 'full_tunnel';
  }
  const storedMode = await safeGetSetting(routingModeKey);
  if (storedMode) {
    return normalizeVpnRoutingMode(storedMode);
  }
  const storedLegacySmartMode = await safeGetSetting(smartRoutingEnabledKey);
  if (storedLegacySmartMode === 'false') {
    return 'full_tunnel';
  }
  if (storedLegacySmartMode === 'true') {
    return 'all_except_ru';
  }
  return defaultVpnRoutingMode;
}

export async function setVpnRoutingMode(mode: VpnRoutingMode): Promise<VpnRoutingMode> {
  const normalized = Platform.OS === 'android' && !androidRoutingExperiment
    ? 'full_tunnel'
    : normalizeVpnRoutingMode(mode);
  await SecureStore.setItemAsync(routingModeKey, normalized);
  await SecureStore.setItemAsync(smartRoutingEnabledKey, isSmartRoutingMode(normalized) ? 'true' : 'false');
  return normalized;
}

export async function getSmartRoutingEnabled(): Promise<boolean> {
  return isSmartRoutingMode(await getVpnRoutingMode());
}

export async function setSmartRoutingEnabled(enabled: boolean): Promise<boolean> {
  await setVpnRoutingMode(enabled ? 'all_except_ru' : 'full_tunnel');
  return enabled;
}

export async function getServerSelectionMode(): Promise<ServerSelectionMode> {
  return normalizeServerSelectionMode(await safeGetSetting(serverSelectionModeKey));
}

export async function setServerSelectionMode(mode: ServerSelectionMode): Promise<ServerSelectionMode> {
  const normalized = normalizeServerSelectionMode(mode);
  await SecureStore.setItemAsync(serverSelectionModeKey, normalized);
  return normalized;
}

export async function getSelectedVpnLocation(): Promise<string> {
  const value = (await safeGetSetting(selectedVpnLocationKey))?.trim().toLowerCase();
  return value || defaultVpnLocation;
}

export async function setSelectedVpnLocation(locationId: string): Promise<string> {
  const normalized = locationId.trim().toLowerCase() || defaultVpnLocation;
  await SecureStore.setItemAsync(selectedVpnLocationKey, normalized);
  return normalized;
}

export async function getVpnApplicationSelection(): Promise<VpnApplicationSelection> {
  const [storedMode, storedApplications] = await Promise.all([
    safeGetSetting(vpnApplicationRoutingModeKey),
    safeGetSetting(selectedVpnApplicationsKey),
  ]);
  return {
    mode: storedMode === 'selected' ? 'selected' : 'all',
    packageNames: parseStoredPackageNames(storedApplications),
  };
}

export async function setVpnApplicationRoutingMode(mode: VpnApplicationRoutingMode): Promise<VpnApplicationRoutingMode> {
  const normalized: VpnApplicationRoutingMode = mode === 'selected' ? 'selected' : 'all';
  await SecureStore.setItemAsync(vpnApplicationRoutingModeKey, normalized);
  return normalized;
}

export async function setSelectedVpnApplications(packageNames: string[]): Promise<string[]> {
  const normalized = normalizePackageNames(packageNames);
  await SecureStore.setItemAsync(selectedVpnApplicationsKey, JSON.stringify(normalized));
  return normalized;
}

export async function safeGetSetting(key: string): Promise<string | null> {
  return safeGetStoredValue(key, SecureStore.getItemAsync);
}

function parseStoredPackageNames(value: string | null): string[] {
  if (!value) {
    return [];
  }
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? normalizePackageNames(parsed.filter((item): item is string => typeof item === 'string'))
      : [];
  } catch {
    return [];
  }
}

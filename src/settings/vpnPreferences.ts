import { Platform } from 'react-native';
import * as SecureStore from '@/native/secureStore';
import { safeGetStoredValue } from '@/settings/safeStorage';
import { defaultVpnRoutingMode, isSmartRoutingMode, normalizeVpnRoutingMode, type VpnRoutingMode } from '@/vpn/routingPolicy';
import { normalizeServerSelectionMode, type ServerSelectionMode } from '@/vpn/serverSelection';

const androidAutoConnectKey = 'vex.settings.android.autoconnect.v1';
const antiLeakEnabledKey = 'vex.settings.vpn.anti_leak.v1';
const smartRoutingEnabledKey = 'vex.settings.vpn.smart_routing.v1';
const routingModeKey = 'vex.settings.vpn.routing_mode.v1';
const serverSelectionModeKey = 'vex.settings.vpn.server_selection_mode.v1';
const selectedVpnLocationKey = 'vex.settings.vpn.location.v1';
const defaultVpnLocation = 'de';

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
  return (await safeGetSetting(antiLeakEnabledKey)) !== 'false';
}

export async function setAntiLeakEnabled(enabled: boolean): Promise<boolean> {
  await SecureStore.setItemAsync(antiLeakEnabledKey, enabled ? 'true' : 'false');
  return enabled;
}

export async function getVpnRoutingMode(): Promise<VpnRoutingMode> {
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
  const normalized = normalizeVpnRoutingMode(mode);
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

export async function safeGetSetting(key: string): Promise<string | null> {
  return safeGetStoredValue(key, SecureStore.getItemAsync);
}

import { entitlement, hasPaidEntitlement, preparedTunnel, rotateManagedVpnKey, type Entitlement, type VpnDevice } from '../api/vexApi';
import { loadHotVpnProfile, profileFromHotRecord, saveHotVpnProfile } from './hotProfileCache';
import { defaultVpnBypassRegion, defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, type VpnRoutingMode } from './routingPolicy';

export type VpnProfile = {
  config: string;
  device?: VpnDevice;
  entitlement?: Entitlement;
  hotProfileAgeMs?: number;
  hotProfileUsed?: boolean;
  lastSuccessfulEndpoint?: string;
  locationId: string;
  profileVersion?: number;
  routingMode?: VpnRoutingMode;
  bypassRegion?: string;
  bypassRangesCount?: number;
  bypassDomainsCount?: number;
  routingPolicyVersion?: string;
  rotationRequired?: boolean;
  source: 'local' | 'api';
};

let cachedProfile: { key: string; profile: VpnProfile } | null = null;

export async function resolveVpnProfile(
  accessToken?: string,
  knownEntitlement?: Entitlement | null,
  locationId = 'de',
  options: { allowPersistentHotProfile?: boolean; forceRefresh?: boolean; userId?: string } = {},
): Promise<VpnProfile> {
  const token = accessToken?.trim() || '';
  const normalizedLocationId = normalizeLocationId(locationId);
  const cacheKey = profileCacheKey(token, normalizedLocationId);
  if (!options.forceRefresh) {
    if (cachedProfile?.key === cacheKey && !cachedProfile.profile.rotationRequired) {
      return { ...cachedProfile.profile, source: 'local' };
    }
    if (options.allowPersistentHotProfile !== false && options.userId) {
      const hotProfile = await loadHotVpnProfile(options.userId, normalizedLocationId);
      if (hotProfile) {
        const profile = profileFromHotRecord(hotProfile);
        cachedProfile = { key: cacheKey, profile };
        return profile;
      }
    }
  }

  if (token) {
    return refreshVpnProfile(token, {}, knownEntitlement, normalizedLocationId, options.userId);
  }

  throw new Error('Сначала войдите в аккаунт.');
}

export function resetVpnProfileCache() {
  cachedProfile = null;
}

export async function rotateVpnProfileKey(accessToken: string, profile: VpnProfile): Promise<VpnProfile> {
  const token = accessToken.trim();
  const device = profile.device;
  if (!token || !device?.id) {
    throw new Error('VPN-устройство для ротации не найдено.');
  }
  if (!isManagedClientOwnedDevice(device)) {
    throw new Error('Ротация доступна только для managed native устройства.');
  }

  await rotateManagedVpnKey(token, device.id);
  resetVpnProfileCache();
  return refreshVpnProfile(token, {}, profile.entitlement, profile.locationId);
}

function runtimeProfileKey(): string {
  if (typeof navigator === 'undefined') {
    return 'native';
  }
  const platform = typeof navigator.platform === 'string' && navigator.platform.trim()
    ? navigator.platform
    : 'native';
  const userAgent = typeof navigator.userAgent === 'string' ? navigator.userAgent : '';
  return `${platform}:${userAgent.includes('Tauri') ? 'tauri' : 'runtime'}`;
}

async function refreshVpnProfile(
  token: string,
  options: { cachedConfig?: string; knownVersion?: number; locationId?: string },
  knownEntitlement?: Entitlement | null,
  locationId = 'de',
  userId?: string,
): Promise<VpnProfile> {
  const currentEntitlement = knownEntitlement ?? await entitlement(token);
  if (!hasPaidEntitlement(currentEntitlement)) {
    throw new Error('Подписка не активна.');
  }

  const selectedLocationId = normalizeLocationId(options.locationId || locationId);
  const tunnel = await preparedTunnel(token, undefined, { ...options, locationId: selectedLocationId });
  const profile: VpnProfile = {
    config: tunnel.config,
    device: tunnel.device,
    entitlement: currentEntitlement,
    locationId: selectedLocationId,
    profileVersion: tunnel.profileVersion,
    routingMode: tunnel.routingMode ?? defaultVpnRoutingMode,
    bypassRegion: tunnel.bypassRegion ?? defaultVpnBypassRegion,
    bypassRangesCount: tunnel.bypassRangesCount,
    bypassDomainsCount: tunnel.bypassDomainsCount,
    routingPolicyVersion: tunnel.routingPolicyVersion ?? defaultVpnRoutingPolicyVersion,
    rotationRequired: tunnel.rotationRequired,
    source: 'api',
  };
  cachedProfile = { key: profileCacheKey(token, selectedLocationId), profile };
  if (userId) {
    await saveHotVpnProfile(userId, selectedLocationId, profile).catch(() => undefined);
  }
  return profile;
}

function profileCacheKey(token: string, locationId: string): string {
  return `${token}:${runtimeProfileKey()}:${normalizeLocationId(locationId)}:${defaultVpnRoutingMode}:${defaultVpnBypassRegion}:${defaultVpnRoutingPolicyVersion}`;
}

function normalizeLocationId(locationId: string): string {
  return locationId.trim().toLowerCase() || 'de';
}

function isManagedClientOwnedDevice(device: VpnDevice): boolean {
  return device.provisioningMode === 'managed_native' || device.clientKeyOwnership === 'client';
}

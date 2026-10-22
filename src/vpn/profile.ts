import { entitlement, hasPaidEntitlement, preparedTunnel, rotateManagedVpnKey, type Entitlement, type VpnDevice } from '../api/vexApi';
import { loadHotVpnProfile, profileFromHotRecord } from './hotProfileCache';
import { runtimeProfileKey, vpnProfileCacheIsCurrent } from './hotProfileCacheCore';
import { defaultVpnBypassRegion, defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, type VpnRoutingMode } from './routingPolicy';
import { runProfileRequest } from './profileRequestQueue';
import { vpnProfileAddressMatchesDevice } from './profileConsistency';
import { requireVpnLocationId } from './locationId';
import { profileRevalidationOptions } from './profileRevalidation';
import type { PreparedTunnel, PreparedTunnelOptions } from '../api/types';
import { SessionOperationSupersededError } from './sessionOperation';
import { requireRequestActive } from '../api/error';
import { withRequestCancellation } from '../api/requestCancellation';

export type VpnProfile = {
  routingParameters?: string;
  resolutionTiming?: PreparedTunnel['resolutionTiming'];
  connectPreparationTiming?: {
    startedAtMs: number;
    completedAtMs: number;
    entitlementWaitMs: number;
    hotProfileLookupMs: number;
    keyRotationMs: number;
    permissionWaitMs: number;
  };
  config: string;
  /** Original local cache receipt time; API/wire and persisted schema unchanged. */
  cacheSavedAtMs?: number;
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
  locationId = '',
  options: { signal?: AbortSignal; allowPersistentHotProfile?: boolean; forceRefresh?: boolean; shouldFetch?: () => boolean; isCurrentSessionOperation?: () => boolean; routingMode?: VpnRoutingMode; userId?: string; revalidateProfile?: VpnProfile | null } = {},
): Promise<VpnProfile> {
  return withRequestCancellation(async () => {
    requireProfileRequest(options);
    const token = accessToken?.trim() || '';
    const normalizedLocationId = normalizeLocationId(locationId);
    const routingMode = options.routingMode ?? defaultVpnRoutingMode;
    const cacheKey = profileCacheKey(token, normalizedLocationId, routingMode);
    if (!options.forceRefresh) {
      if (cachedProfile?.key === cacheKey && vpnProfileCacheIsCurrent(cachedProfile.profile) && !cachedProfile.profile.rotationRequired && vpnProfileAddressMatchesDevice(cachedProfile.profile)) {
        return { ...cachedProfile.profile, source: 'local' };
      }
      if (options.allowPersistentHotProfile !== false && options.userId) {
        const hotProfile = await loadHotVpnProfile(options.userId, normalizedLocationId, routingMode);
        requireProfileRequest(options);
        if (hotProfile) {
          const profile = profileFromHotRecord(hotProfile);
          if (profile.routingMode !== routingMode || !vpnProfileCacheIsCurrent(profile) || !vpnProfileAddressMatchesDevice(profile)) {
            return refreshVpnProfile(token, { routingMode, userId: options.userId, isCurrentSessionOperation: options.isCurrentSessionOperation, ...(options.signal ? { signal: options.signal } : {}) }, knownEntitlement, normalizedLocationId, options.shouldFetch);
          }
          cachedProfile = { key: cacheKey, profile };
          return profile;
        }
      }
    }

    if (token) {
      return refreshVpnProfile(token, { ...profileRevalidationOptions(options.revalidateProfile, normalizedLocationId, routingMode), routingMode, userId: options.userId, isCurrentSessionOperation: options.isCurrentSessionOperation, ...(options.signal ? { signal: options.signal } : {}) }, knownEntitlement, normalizedLocationId, options.shouldFetch);
    }

    throw new Error('Сначала войдите в аккаунт.');
  }, options.signal);
}

export function resetVpnProfileCache() {
  cachedProfile = null;
}

export async function rotateVpnProfileKey(accessToken: string, profile: VpnProfile, isCurrentSessionOperation?: () => boolean, userId?: string): Promise<VpnProfile> {
  requireCurrentSession(isCurrentSessionOperation);
  const token = accessToken.trim();
  const device = profile.device;
  if (!token || !device?.id) {
    throw new Error('VPN-устройство для ротации не найдено.');
  }
  if (!isManagedClientOwnedDevice(device)) {
    throw new Error('Ротация доступна только для managed native устройства.');
  }

  await rotateManagedVpnKey(token, device.id, device.keyEpoch, isCurrentSessionOperation, userId);
  requireCurrentSession(isCurrentSessionOperation);
  resetVpnProfileCache();
  return refreshVpnProfile(token, { routingMode: profile.routingMode ?? defaultVpnRoutingMode, userId, isCurrentSessionOperation }, profile.entitlement, profile.locationId);
}

async function refreshVpnProfile(
  token: string,
  options: PreparedTunnelOptions,
  knownEntitlement?: Entitlement | null,
  locationId = '',
  shouldFetch?: () => boolean,
): Promise<VpnProfile> {
  requireProfileRequest(options);
  const currentEntitlement = knownEntitlement ?? await entitlement(token, options.signal);
  requireProfileRequest(options);
  if (!hasPaidEntitlement(currentEntitlement)) {
    throw new Error('Подписка не активна.');
  }

  const selectedLocationId = normalizeLocationId(options.locationId || locationId);
  const routingMode = options.routingMode ?? defaultVpnRoutingMode;
  const queuedAtMs = Date.now();
  let queueWaitMs = 0;
  const coalesceKey = profileRequestCoalesceKey(token, selectedLocationId, routingMode, options);
  const tunnel = await runProfileRequest((signal) => {
    requireCurrentSession(options.isCurrentSessionOperation);
    requireRequestActive(signal);
    queueWaitMs = Math.max(0, Date.now() - queuedAtMs);
    return preparedTunnel(token, undefined, { ...options, signal, locationId: selectedLocationId, routingMode });
  }, shouldFetch, shouldFetch ? 'background' : 'foreground', coalesceKey, options.signal);
  requireProfileRequest(options);
  const profile: VpnProfile = {
    cacheSavedAtMs: Date.now(),
    resolutionTiming: tunnel.resolutionTiming ? { ...tunnel.resolutionTiming, queueWaitMs } : undefined,
    config: tunnel.config,
    routingParameters: tunnel.routingParameters,
    device: tunnel.device,
    entitlement: currentEntitlement,
    locationId: selectedLocationId,
    profileVersion: tunnel.profileVersion,
    routingMode: tunnel.routingMode ?? routingMode,
    bypassRegion: tunnel.bypassRegion ?? defaultVpnBypassRegion,
    bypassRangesCount: tunnel.bypassRangesCount,
    bypassDomainsCount: tunnel.bypassDomainsCount,
    routingPolicyVersion: tunnel.routingPolicyVersion ?? defaultVpnRoutingPolicyVersion,
    rotationRequired: tunnel.rotationRequired,
    source: 'api',
  };
  cachedProfile = { key: profileCacheKey(token, selectedLocationId, routingMode), profile };
  // useVpnProfileState owns persistent caching after scope validation. Returning
  // a ready profile must not wait for a duplicate secure-store read/write here.
  return profile;
}

function profileCacheKey(token: string, locationId: string, routingMode: VpnRoutingMode): string {
  return `${token}:${runtimeProfileKey()}:${normalizeLocationId(locationId)}:${routingMode}:${defaultVpnBypassRegion}:${defaultVpnRoutingPolicyVersion}`;
}

function profileRequestCoalesceKey(token: string, locationId: string, routingMode: VpnRoutingMode, options: PreparedTunnelOptions): string {
  const bypassRegion = (options.bypassRegion ?? defaultVpnBypassRegion).trim().toLowerCase();
  const cachedDevice = options.cachedDevice;
  const revalidation = options.cachedConfig && cachedDevice?.id && Number.isInteger(options.knownVersion) && (options.knownVersion ?? 0) > 0
    ? `revalidate:${cachedDevice.id}:${options.knownVersion}:${cachedDevice.keyEpoch ?? 0}:${cachedDevice.assignedIpv4 ?? ''}`
    : 'fresh';
  return `${profileCacheKey(token, locationId, routingMode)}:${bypassRegion}:${revalidation}`;
}

function normalizeLocationId(locationId: string): string {
  return requireVpnLocationId(locationId);
}

function requireProfileRequest(options: PreparedTunnelOptions): void {
  requireCurrentSession(options.isCurrentSessionOperation);
  requireRequestActive(options.signal);
}

function requireCurrentSession(isCurrentSessionOperation?: () => boolean): void {
  if (isCurrentSessionOperation && !isCurrentSessionOperation()) {
    throw new SessionOperationSupersededError();
  }
}

function isManagedClientOwnedDevice(device: VpnDevice): boolean {
  return device.provisioningMode === 'managed_native' || device.clientKeyOwnership === 'client';
}

import { Platform } from 'react-native';
import type { QueryClient } from '@tanstack/react-query';

import * as SecureStore from '@/native/secureStore';
import { updateStoredJsonObject } from '@/native/storedJsonObject';
import type { VpnProfile } from './profile';
import { defaultVpnRoutingMode } from './routingPolicy';
import {
  hotVpnProfileSchemaVersion,
  hotVpnProfilesStorageKey,
  hotVpnProfileRejectionReason,
  hotVpnProfileStoreKey,
  isUsableHotVpnProfileRecord as isUsableHotVpnProfileRecordForRuntime,
  normalizeHotProfileLocationId,
  profileFromHotRecord,
  type HotVpnProfileRecord,
} from './hotProfileCacheCore';

export {
  hotVpnProfileSchemaVersion,
  hotVpnProfilesStorageKey,
  hotVpnProfileTtlMs,
  isUsableHotVpnProfileRecord,
  profileFromHotRecord,
  withLastSuccessfulEndpoint,
  type HotVpnProfileRecord,
} from './hotProfileCacheCore';

export type HotVpnProfileMetadata = {
  lastSuccessfulEndpoint?: string;
  nowMs?: number;
};

export type HotVpnProfileLoadResult =
  | { record: HotVpnProfileRecord; rejectedReason?: undefined }
  | { record: null; rejectedReason?: string };

export function supportsPersistentHotVpnProfiles(): boolean {
  if (Platform.OS === 'android' || Platform.OS === 'ios') {
    return true;
  }
  return false;
}

export async function loadHotVpnProfile(
  userId: string,
  locationId: string,
  routingModeOrNowMs?: string | number,
  nowMs = Date.now(),
): Promise<HotVpnProfileRecord | null> {
  return (await loadHotVpnProfileResult(userId, locationId, routingModeOrNowMs, nowMs)).record;
}

export async function loadHotVpnProfileResult(
  userId: string,
  locationId: string,
  routingModeOrNowMs?: string | number,
  nowMs = Date.now(),
): Promise<HotVpnProfileLoadResult> {
  if (!supportsPersistentHotVpnProfiles()) {
    return { record: null };
  }
  const routingMode = typeof routingModeOrNowMs === 'string' ? routingModeOrNowMs : undefined;
  const effectiveNowMs = typeof routingModeOrNowMs === 'number' ? routingModeOrNowMs : nowMs;
  const key = hotVpnProfileStoreKey(userId, locationId, runtimeProfileKey(), routingMode);
  return updateStoredJsonObject<HotVpnProfileRecord, HotVpnProfileLoadResult>(hotVpnProfilesStorageKey, (store) => {
    const record = store[key];
    const rejectedReason = hotVpnProfileRejectionReason(record, userId, locationId, runtimeProfileKey(), effectiveNowMs);
    if (rejectedReason !== null) {
      delete store[key];
      return { record: null, rejectedReason };
    }
    return { record };
  }).catch(() => ({ record: null }));
}

export async function saveHotVpnProfile(
  userId: string,
  locationId: string,
  profile: VpnProfile,
  metadata: HotVpnProfileMetadata = {},
): Promise<HotVpnProfileRecord | null> {
  if (!supportsPersistentHotVpnProfiles() || profile.rotationRequired) {
    return null;
  }
  const storedProfile = { ...profile, source: 'local' as const };
  delete storedProfile.connectPreparationTiming;
  delete storedProfile.hotProfileAgeMs;
  delete storedProfile.hotProfileUsed;
  // The native policy cache re-verifies public routing data on reuse. Avoid
  // duplicating a large authorization envelope in secret profile storage.
  delete storedProfile.routingParameters;
  const record: HotVpnProfileRecord = {
    schemaVersion: hotVpnProfileSchemaVersion,
    userId: userId.trim(),
    runtimeKey: runtimeProfileKey(),
    locationId: normalizeHotProfileLocationId(locationId || profile.locationId),
    profile: storedProfile,
    savedAtMs: metadata.nowMs ?? Date.now(),
    lastSuccessfulEndpoint: normalizeOptionalEndpoint(metadata.lastSuccessfulEndpoint),
  };
  await updateStoredJsonObject<HotVpnProfileRecord, void>(hotVpnProfilesStorageKey, (store) => {
    store[hotVpnProfileStoreKey(userId, locationId || profile.locationId, runtimeProfileKey(), profile.routingMode)] = record;
  });
  return record;
}

export async function clearHotVpnProfiles(userId?: string): Promise<void> {
  if (!supportsPersistentHotVpnProfiles()) {
    return;
  }
  if (!userId?.trim()) {
    await SecureStore.deleteItemAsync(hotVpnProfilesStorageKey);
    return;
  }
  const normalizedUserId = userId.trim();
  await updateStoredJsonObject<HotVpnProfileRecord, void>(hotVpnProfilesStorageKey, (store) => {
    for (const [key, record] of Object.entries(store)) {
      if (record?.userId === normalizedUserId) delete store[key];
    }
  });
}

export async function hydrateHotVpnProfilesToQueryCache(
  userId: string,
  accessToken: string,
  queryClient: QueryClient,
  nowMs = Date.now(),
  isCurrent: () => boolean = () => true,
): Promise<HotVpnProfileRecord[]> {
  if (!supportsPersistentHotVpnProfiles()) {
    return [];
  }
  const records = await updateStoredJsonObject<HotVpnProfileRecord, HotVpnProfileRecord[]>(hotVpnProfilesStorageKey, (store) => {
    if (!isCurrent()) return [];
    const usable: HotVpnProfileRecord[] = [];
    for (const [key, record] of Object.entries(store)) {
      if (!isUsableHotVpnProfileRecordForRuntime(record, userId, record?.locationId, runtimeProfileKey(), nowMs)) {
        delete store[key];
        continue;
      }
      usable.push({ ...record, profile: profileFromHotRecord(record, nowMs) });
    }
    return usable;
  }).catch(() => []);
  for (const record of records) {
    if (!isCurrent()) return [];
    const profile = record.profile;
    queryClient.setQueryData(['vpn-profile', accessToken, record.locationId, profile.routingMode ?? defaultVpnRoutingMode], profile);
    if (!isCurrent()) return [];
    if (profile.entitlement) {
      queryClient.setQueryData(['entitlement', accessToken], profile.entitlement);
    }
  }
  return records;
}

export function runtimeProfileKey(): string {
  if (typeof navigator === 'undefined') {
    return 'native';
  }
  const platform = typeof navigator.platform === 'string' && navigator.platform.trim()
    ? navigator.platform
    : 'native';
  const userAgent = typeof navigator.userAgent === 'string' ? navigator.userAgent : '';
  return `${platform}:${userAgent || 'runtime'}`;
}

function normalizeOptionalEndpoint(endpoint?: string): string | undefined {
  const value = endpoint?.trim();
  return value || undefined;
}

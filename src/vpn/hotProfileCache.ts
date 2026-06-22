import { Platform } from 'react-native';
import type { QueryClient } from '@tanstack/react-query';

import * as SecureStore from '@/native/secureStore';
import type { VpnProfile } from './profile';
import {
  hotVpnProfileSchemaVersion,
  hotVpnProfilesStorageKey,
  hotVpnProfileRejectionReason,
  hotVpnProfileStoreKey,
  isUsableHotVpnProfileRecord as isUsableHotVpnProfileRecordForRuntime,
  normalizeHotProfileLocationId,
  profileFromHotRecord,
  withLastSuccessfulEndpoint,
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

type HotVpnProfileStore = Record<string, HotVpnProfileRecord>;

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
  return Platform.OS === 'web' && typeof window !== 'undefined' && (
    '__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window
  );
}

export async function loadHotVpnProfile(
  userId: string,
  locationId: string,
  nowMs = Date.now(),
): Promise<HotVpnProfileRecord | null> {
  return (await loadHotVpnProfileResult(userId, locationId, nowMs)).record;
}

export async function loadHotVpnProfileResult(
  userId: string,
  locationId: string,
  nowMs = Date.now(),
): Promise<HotVpnProfileLoadResult> {
  if (!supportsPersistentHotVpnProfiles()) {
    return { record: null };
  }
  const store = await readHotVpnProfileStore();
  const key = hotVpnProfileStoreKey(userId, locationId, runtimeProfileKey());
  const record = store[key];
  if (!isUsableHotVpnProfileRecordForRuntime(record, userId, locationId, runtimeProfileKey(), nowMs)) {
    const rejectedReason = hotVpnProfileRejectionReason(record, userId, locationId, runtimeProfileKey(), nowMs) ?? undefined;
    if (record) {
      delete store[key];
      await writeHotVpnProfileStore(store);
    }
    return { record: null, rejectedReason };
  }
  return { record };
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
  const store = await readHotVpnProfileStore();
  const storedProfile = { ...profile, source: 'local' as const };
  delete storedProfile.hotProfileAgeMs;
  delete storedProfile.hotProfileUsed;
  const record: HotVpnProfileRecord = {
    schemaVersion: hotVpnProfileSchemaVersion,
    userId: userId.trim(),
    runtimeKey: runtimeProfileKey(),
    locationId: normalizeHotProfileLocationId(locationId || profile.locationId),
    profile: storedProfile,
    savedAtMs: metadata.nowMs ?? Date.now(),
    lastSuccessfulEndpoint: normalizeOptionalEndpoint(metadata.lastSuccessfulEndpoint),
  };
  store[hotVpnProfileStoreKey(userId, locationId || profile.locationId, runtimeProfileKey())] = record;
  await writeHotVpnProfileStore(store);
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
  const store = await readHotVpnProfileStore();
  const normalizedUserId = userId.trim();
  for (const [key, record] of Object.entries(store)) {
    if (record.userId === normalizedUserId) {
      delete store[key];
    }
  }
  await writeHotVpnProfileStore(store);
}

export async function hydrateHotVpnProfilesToQueryCache(
  userId: string,
  accessToken: string,
  queryClient: QueryClient,
  nowMs = Date.now(),
): Promise<HotVpnProfileRecord[]> {
  if (!supportsPersistentHotVpnProfiles()) {
    return [];
  }
  const store = await readHotVpnProfileStore();
  const records: HotVpnProfileRecord[] = [];
  let changed = false;
  for (const [key, record] of Object.entries(store)) {
    if (!isUsableHotVpnProfileRecordForRuntime(record, userId, record.locationId, runtimeProfileKey(), nowMs)) {
      delete store[key];
      changed = true;
      continue;
    }
    const profile = profileFromHotRecord(record, nowMs);
    queryClient.setQueryData(['vpn-profile', accessToken, record.locationId], profile);
    if (profile.entitlement) {
      queryClient.setQueryData(['entitlement', accessToken], profile.entitlement);
    }
    records.push({ ...record, profile });
  }
  if (changed) {
    await writeHotVpnProfileStore(store);
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
  return `${platform}:${userAgent.includes('Tauri') ? 'tauri' : 'runtime'}`;
}

async function readHotVpnProfileStore(): Promise<HotVpnProfileStore> {
  const raw = await SecureStore.getItemAsync(hotVpnProfilesStorageKey).catch(() => null);
  if (!raw) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

async function writeHotVpnProfileStore(store: HotVpnProfileStore): Promise<void> {
  if (Object.keys(store).length === 0) {
    await SecureStore.deleteItemAsync(hotVpnProfilesStorageKey).catch(() => undefined);
    return;
  }
  await SecureStore.setItemAsync(hotVpnProfilesStorageKey, JSON.stringify(store));
}

function normalizeOptionalEndpoint(endpoint?: string): string | undefined {
  const value = endpoint?.trim();
  return value || undefined;
}

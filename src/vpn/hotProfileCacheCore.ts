import type { VpnProfile } from './profile';

export const hotVpnProfilesStorageKey = 'vex.vpn.hot_profiles.v1';
export const hotVpnProfileSchemaVersion = 2;
export const hotVpnProfileTtlMs = 24 * 60 * 60_000;

export type HotVpnProfileRecord = {
  schemaVersion: number;
  userId: string;
  runtimeKey: string;
  locationId: string;
  profile: VpnProfile;
  savedAtMs: number;
  lastSuccessfulEndpoint?: string;
};

export function withLastSuccessfulEndpoint(profile: VpnProfile, endpoint?: string): VpnProfile {
  const normalizedEndpoint = normalizeOptionalEndpoint(endpoint);
  return normalizedEndpoint ? { ...profile, lastSuccessfulEndpoint: normalizedEndpoint } : profile;
}

export function profileFromHotRecord(record: HotVpnProfileRecord, nowMs = Date.now()): VpnProfile {
  return {
    ...record.profile,
    hotProfileAgeMs: Math.max(0, nowMs - record.savedAtMs),
    hotProfileUsed: true,
    lastSuccessfulEndpoint: record.lastSuccessfulEndpoint ?? record.profile.lastSuccessfulEndpoint,
    source: 'local',
  };
}

export function isUsableHotVpnProfileRecord(
  value: unknown,
  userId: string,
  locationId: string,
  runtimeKey: string,
  nowMs = Date.now(),
): value is HotVpnProfileRecord {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const record = value as Partial<HotVpnProfileRecord>;
  if (record.schemaVersion !== hotVpnProfileSchemaVersion) {
    return false;
  }
  if (record.userId !== userId.trim()) {
    return false;
  }
  if (record.runtimeKey !== runtimeKey) {
    return false;
  }
  if (normalizeLocationId(record.locationId || '') !== normalizeLocationId(locationId)) {
    return false;
  }
  if (!record.profile?.config || record.profile.rotationRequired) {
    return false;
  }
  return typeof record.savedAtMs === 'number' && nowMs - record.savedAtMs <= hotVpnProfileTtlMs;
}

export function hotVpnProfileRejectionReason(
  value: unknown,
  userId: string,
  locationId: string,
  runtimeKey: string,
  nowMs = Date.now(),
): string | null {
  if (!value || typeof value !== 'object') {
    return 'missing';
  }
  const record = value as Partial<HotVpnProfileRecord>;
  if (record.schemaVersion !== hotVpnProfileSchemaVersion) {
    return 'schema_mismatch';
  }
  if (record.userId !== userId.trim()) {
    return 'user_mismatch';
  }
  if (record.runtimeKey !== runtimeKey) {
    return 'runtime_mismatch';
  }
  if (normalizeLocationId(record.locationId || '') !== normalizeLocationId(locationId)) {
    return 'location_mismatch';
  }
  if (!record.profile?.config) {
    return 'missing_config';
  }
  if (record.profile.rotationRequired) {
    return 'rotation_required';
  }
  if (typeof record.savedAtMs !== 'number') {
    return 'missing_saved_at';
  }
  if (nowMs - record.savedAtMs > hotVpnProfileTtlMs) {
    return 'expired';
  }
  return null;
}

export function hotVpnProfileStoreKey(userId: string, locationId: string, runtimeKey: string, routingMode?: string): string {
  const normalizedRoutingMode = routingMode?.trim().toLowerCase();
  return `${userId.trim()}:${runtimeKey}:${normalizeLocationId(locationId)}:${normalizedRoutingMode || 'default'}`;
}

export function normalizeHotProfileLocationId(locationId: string): string {
  return normalizeLocationId(locationId);
}

function normalizeLocationId(locationId: string): string {
  return locationId.trim().toLowerCase() || 'de';
}

function normalizeOptionalEndpoint(endpoint?: string): string | undefined {
  const value = endpoint?.trim();
  return value || undefined;
}

import type { VpnProfile } from './profile';
import { comparableVpnLocationId, requireVpnLocationId } from './locationId';

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
  return hotVpnProfileRejectionReason(value, userId, locationId, runtimeKey, nowMs) === null;
}

export function hotVpnProfileRejectionReason(
  value: unknown,
  userId: string,
  locationId: string,
  runtimeKey: string,
  nowMs = Date.now(),
): string | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
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
  if (typeof record.locationId !== 'string' || typeof locationId !== 'string'
    || normalizeLocationId(record.locationId) !== normalizeLocationId(locationId)) {
    return 'location_mismatch';
  }
  if (!record.profile || typeof record.profile !== 'object' || Array.isArray(record.profile)
    || typeof record.profile.config !== 'string' || !record.profile.config.trim()) {
    return 'missing_config';
  }
  if (record.profile.rotationRequired) {
    return 'rotation_required';
  }
  if (typeof record.savedAtMs !== 'number' || !Number.isFinite(record.savedAtMs) || record.savedAtMs < 0) {
    return 'missing_saved_at';
  }
  if (!Number.isFinite(nowMs) || nowMs < 0) {
    return 'invalid_clock';
  }
  if (nowMs < record.savedAtMs) {
    return 'future_saved_at';
  }
  if (nowMs - record.savedAtMs > hotVpnProfileTtlMs) {
    return 'expired';
  }
  return null;
}

export function hotVpnProfileStoreKey(userId: string, locationId: string, runtimeKey: string, routingMode?: string): string {
  const normalizedRoutingMode = routingMode?.trim().toLowerCase();
  return `${userId.trim()}:${runtimeKey}:${comparableVpnLocationId(requireVpnLocationId(locationId))}:${normalizedRoutingMode || 'default'}`;
}

export function normalizeHotProfileLocationId(locationId: string): string {
  return requireVpnLocationId(locationId);
}

function normalizeLocationId(locationId: string): string {
  return comparableVpnLocationId(locationId);
}

function normalizeOptionalEndpoint(endpoint?: string): string | undefined {
  const value = endpoint?.trim();
  return value || undefined;
}

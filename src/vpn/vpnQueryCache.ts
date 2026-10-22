import type { Entitlement, VpnDevice, VpnLocation } from '@/api/vexApi';
import { updateStoredJsonObject } from '@/native/storedJsonObject';
import {
  baseVpnQueryCacheSchemaVersion,
  locationCatalogCacheSchemaVersion,
  validCachedValueForUser,
  type VpnQueryCacheEntry,
} from './vpnQueryCachePolicy';

const entitlementCacheKey = 'vex.entitlement.v1';
const locationsCacheKey = 'vex.vpn.locations.v1';
const devicesCacheKey = 'vex.vpn.devices.v1';

export async function loadCachedEntitlement(userId: string): Promise<Entitlement | null> {
  return loadCachedValue(entitlementCacheKey, userId, isEntitlement);
}

export async function saveCachedEntitlement(userId: string, value: Entitlement): Promise<void> {
  await saveCachedValue(entitlementCacheKey, userId, value);
}

export async function loadCachedVpnLocations(userId: string): Promise<VpnLocation[] | null> {
  return loadCachedValue(locationsCacheKey, userId, isVpnLocations, locationCatalogCacheSchemaVersion);
}

export async function saveCachedVpnLocations(userId: string, value: VpnLocation[]): Promise<void> {
  await saveCachedValue(locationsCacheKey, userId, value, locationCatalogCacheSchemaVersion);
}

export async function loadCachedVpnDevices(userId: string): Promise<VpnDevice[] | null> {
  return loadCachedValue(devicesCacheKey, userId, isVpnDevices);
}

export async function saveCachedVpnDevices(userId: string, value: VpnDevice[]): Promise<void> {
  await saveCachedValue(devicesCacheKey, userId, value);
}

async function loadCachedValue<T>(
  storageKey: string,
  userId: string,
  isValid: (value: unknown) => value is T,
  schemaVersion = baseVpnQueryCacheSchemaVersion,
): Promise<T | null> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return null;
  }
  return updateStoredJsonObject<VpnQueryCacheEntry<T>, T | null>(storageKey, (store) => {
    const value = validCachedValueForUser(store[normalizedUserId], normalizedUserId, schemaVersion, isValid);
    if (value === null) delete store[normalizedUserId];
    return value;
  }).catch(() => null);
}

async function saveCachedValue<T>(storageKey: string, userId: string, value: T, schemaVersion = baseVpnQueryCacheSchemaVersion): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  await updateStoredJsonObject<VpnQueryCacheEntry<T>, void>(storageKey, (store) => {
    store[normalizedUserId] = {
      savedAtMs: Date.now(),
      schemaVersion,
      userId: normalizedUserId,
      value,
    };
  });
}

function isEntitlement(value: unknown): value is Entitlement {
  return Boolean(
    value
      && typeof value === 'object'
      && typeof (value as Entitlement).active === 'boolean'
      && typeof (value as Entitlement).vpnAccess === 'boolean',
  );
}

function isVpnLocations(value: unknown): value is VpnLocation[] {
  return Array.isArray(value)
    && value.every((item) => item
      && typeof item.id === 'string'
      && typeof item.countryCode === 'string'
      && typeof item.city === 'string'
      && typeof item.displayName === 'string'
      && typeof item.availability === 'string'
      && typeof item.priority === 'number'
      && typeof item.status === 'string'
      && typeof item.healthyNodes === 'number'
      && (item.awg3Nodes === undefined || (Number.isSafeInteger(item.awg3Nodes) && item.awg3Nodes >= 0))
      && Array.isArray(item.capabilities)
      && item.capabilities.every((capability: unknown) => typeof capability === 'string'));
}

function isVpnDevices(value: unknown): value is VpnDevice[] {
  return Array.isArray(value)
    && value.every((item) => item && typeof item.id === 'string' && typeof item.status === 'string');
}

function normalizeUserId(userId: string): string {
  return userId.trim();
}

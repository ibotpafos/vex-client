import type { Entitlement, VpnDevice, VpnLocation } from '@/api/vexApi';
import * as SecureStore from '@/native/secureStore';
import {
  baseVpnQueryCacheSchemaVersion,
  locationCatalogCacheSchemaVersion,
  validCachedValueForUser,
  type VpnQueryCacheEntry,
} from './vpnQueryCachePolicy';

const entitlementCacheKey = 'vex.entitlement.v1';
const locationsCacheKey = 'vex.vpn.locations.v1';
const devicesCacheKey = 'vex.vpn.devices.v1';
type CacheStore<T> = Record<string, VpnQueryCacheEntry<T>>;

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
  const store = await readStore<T>(storageKey);
  const entry = store[normalizedUserId];
  const value = validCachedValueForUser(entry, normalizedUserId, schemaVersion, isValid);
  if (value === null) {
    if (entry) {
      delete store[normalizedUserId];
      await writeStore(storageKey, store);
    }
    return null;
  }
  return value;
}

async function saveCachedValue<T>(storageKey: string, userId: string, value: T, schemaVersion = baseVpnQueryCacheSchemaVersion): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  const store = await readStore<T>(storageKey);
  store[normalizedUserId] = {
    savedAtMs: Date.now(),
    schemaVersion,
    userId: normalizedUserId,
    value,
  };
  await writeStore(storageKey, store);
}

async function readStore<T>(storageKey: string): Promise<CacheStore<T>> {
  const raw = await SecureStore.getItemAsync(storageKey).catch(() => null);
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

async function writeStore<T>(storageKey: string, store: CacheStore<T>): Promise<void> {
  if (Object.keys(store).length === 0) {
    await SecureStore.deleteItemAsync(storageKey).catch(() => undefined);
    return;
  }
  await SecureStore.setItemAsync(storageKey, JSON.stringify(store));
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

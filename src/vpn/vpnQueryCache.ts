import type { Entitlement, VpnDevice, VpnLocation } from '@/api/vexApi';
import * as SecureStore from '@/native/secureStore';
import {
  devicesCacheTtlMs,
  entitlementCacheTtlMs,
  locationsCacheTtlMs,
  vpnQueryCacheFreshness,
} from './vpnQueryCacheCore';

const entitlementCacheKey = 'vex.entitlement.v1';
const locationsCacheKey = 'vex.vpn.locations.v1';
const devicesCacheKey = 'vex.vpn.devices.v1';
const cacheSchemaVersion = 2;

type CacheEntry<T> = {
  expiresAtMs: number;
  savedAtMs: number;
  schemaVersion: number;
  staleAtMs: number;
  userId: string;
  value: T;
};

type CacheStore<T> = Record<string, CacheEntry<T>>;

export async function loadCachedEntitlement(userId: string): Promise<Entitlement | null> {
  return loadCachedValue(entitlementCacheKey, userId, isEntitlement, entitlementCacheTtlMs);
}

export async function saveCachedEntitlement(userId: string, value: Entitlement): Promise<void> {
  await saveCachedValue(entitlementCacheKey, userId, value, entitlementCacheTtlMs);
}

export async function loadCachedVpnLocations(userId: string): Promise<VpnLocation[] | null> {
  return loadCachedValue(locationsCacheKey, userId, isVpnLocations, locationsCacheTtlMs);
}

export async function saveCachedVpnLocations(userId: string, value: VpnLocation[]): Promise<void> {
  await saveCachedValue(locationsCacheKey, userId, value, locationsCacheTtlMs);
}

export async function loadCachedVpnDevices(userId: string): Promise<VpnDevice[] | null> {
  return loadCachedValue(devicesCacheKey, userId, isVpnDevices, devicesCacheTtlMs);
}

export async function saveCachedVpnDevices(userId: string, value: VpnDevice[]): Promise<void> {
  await saveCachedValue(devicesCacheKey, userId, value, devicesCacheTtlMs);
}

export async function clearVpnQueryCaches(userId: string): Promise<void> {
  await Promise.all([
    clearCachedValue(entitlementCacheKey, userId),
    clearCachedValue(locationsCacheKey, userId),
    clearCachedValue(devicesCacheKey, userId),
  ]);
}

async function loadCachedValue<T>(
  storageKey: string,
  userId: string,
  isValid: (value: unknown) => value is T,
  ttlMs: number,
): Promise<T | null> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return null;
  }
  const store = await readStore<T>(storageKey);
  const entry = store[normalizedUserId];
  if (!isValidEntry(entry, normalizedUserId, isValid, ttlMs)) {
    if (entry) {
      delete store[normalizedUserId];
      await writeStore(storageKey, store);
    }
    return null;
  }
  return entry.value;
}

async function clearCachedValue<T>(storageKey: string, userId: string): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) return;
  const store = await readStore<T>(storageKey);
  if (!(normalizedUserId in store)) return;
  delete store[normalizedUserId];
  await writeStore(storageKey, store);
}

async function saveCachedValue<T>(storageKey: string, userId: string, value: T, ttlMs: number): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  const store = await readStore<T>(storageKey);
  const savedAtMs = Date.now();
  store[normalizedUserId] = {
    expiresAtMs: savedAtMs + ttlMs * 2,
    savedAtMs,
    schemaVersion: cacheSchemaVersion,
    staleAtMs: savedAtMs + ttlMs,
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

function isValidEntry<T>(
  value: CacheEntry<T> | undefined,
  userId: string,
  isValid: (entryValue: unknown) => entryValue is T,
  ttlMs: number,
): value is CacheEntry<T> {
  return Boolean(
    value
      && value.schemaVersion === cacheSchemaVersion
      && value.userId === userId
      && value.staleAtMs === value.savedAtMs + ttlMs
      && value.expiresAtMs === value.savedAtMs + ttlMs * 2
      && vpnQueryCacheFreshness(value.savedAtMs, Date.now(), ttlMs) !== 'expired'
      && isValid(value.value),
  );
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
    && value.every((item) => item && typeof item.id === 'string' && typeof item.healthyNodes === 'number');
}

function isVpnDevices(value: unknown): value is VpnDevice[] {
  return Array.isArray(value)
    && value.every((item) => item && typeof item.id === 'string' && typeof item.status === 'string');
}

function normalizeUserId(userId: string): string {
  return userId.trim();
}

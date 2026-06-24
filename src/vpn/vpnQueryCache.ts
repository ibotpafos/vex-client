import type { Entitlement, VpnDevice, VpnLocation } from '@/api/vexApi';
import * as SecureStore from '@/native/secureStore';

const entitlementCacheKey = 'vex.entitlement.v1';
const locationsCacheKey = 'vex.vpn.locations.v1';
const devicesCacheKey = 'vex.vpn.devices.v1';
const cacheSchemaVersion = 1;

type CacheEntry<T> = {
  savedAtMs: number;
  schemaVersion: number;
  userId: string;
  value: T;
};

type CacheStore<T> = Record<string, CacheEntry<T>>;

export async function loadCachedEntitlement(userId: string): Promise<Entitlement | null> {
  return loadCachedValue(entitlementCacheKey, userId, isEntitlement);
}

export async function saveCachedEntitlement(userId: string, value: Entitlement): Promise<void> {
  await saveCachedValue(entitlementCacheKey, userId, value);
}

export async function loadCachedVpnLocations(userId: string): Promise<VpnLocation[] | null> {
  return loadCachedValue(locationsCacheKey, userId, isVpnLocations);
}

export async function saveCachedVpnLocations(userId: string, value: VpnLocation[]): Promise<void> {
  await saveCachedValue(locationsCacheKey, userId, value);
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
): Promise<T | null> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return null;
  }
  const store = await readStore<T>(storageKey);
  const entry = store[normalizedUserId];
  if (!isValidEntry(entry, normalizedUserId, isValid)) {
    if (entry) {
      delete store[normalizedUserId];
      await writeStore(storageKey, store);
    }
    return null;
  }
  return entry.value;
}

async function saveCachedValue<T>(storageKey: string, userId: string, value: T): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  const store = await readStore<T>(storageKey);
  store[normalizedUserId] = {
    savedAtMs: Date.now(),
    schemaVersion: cacheSchemaVersion,
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
): value is CacheEntry<T> {
  return Boolean(
    value
      && value.schemaVersion === cacheSchemaVersion
      && value.userId === userId
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

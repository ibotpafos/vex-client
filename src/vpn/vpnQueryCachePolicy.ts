export const baseVpnQueryCacheSchemaVersion = 1;
export const locationCatalogCacheSchemaVersion = 2;

export type VpnQueryCacheEntry<T> = {
  savedAtMs: number;
  schemaVersion: number;
  userId: string;
  value: T;
};

export type VpnCacheSession = {
  userId?: string | null;
  accessToken?: string | null;
};

export function shouldResetVpnCacheForSession(
  previous: VpnCacheSession | null,
  next: VpnCacheSession,
): boolean {
  const previousUserId = previous?.userId?.trim() ?? '';
  const nextUserId = next.userId?.trim() ?? '';
  return previous === null ? nextUserId !== '' : previousUserId !== nextUserId;
}

export function validCachedValueForUser<T>(
  entry: VpnQueryCacheEntry<unknown> | undefined,
  userId: string,
  schemaVersion: number,
  isValid: (value: unknown) => value is T,
): T | null {
  const normalizedUserId = userId.trim();
  if (!entry
    || entry.schemaVersion !== schemaVersion
    || entry.userId !== normalizedUserId
    || !isValid(entry.value)) {
    return null;
  }
  return entry.value;
}

export const baseVpnQueryCacheSchemaVersion = 1;
export const locationCatalogCacheSchemaVersion = 2;

export type VpnQueryCacheEntry<T> = {
  savedAtMs: number;
  schemaVersion: number;
  userId: string;
  value: T;
};

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

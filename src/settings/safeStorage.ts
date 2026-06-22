export type StorageGetter = (key: string) => Promise<string | null>;

export async function safeGetStoredValue(key: string, getItem: StorageGetter): Promise<string | null> {
  return getItem(key).catch(() => null);
}

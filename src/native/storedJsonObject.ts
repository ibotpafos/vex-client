import { updateItemAsync } from './secureStore';

/** Edit a JSON object without racing another edit or a direct key deletion. */
export async function updateStoredJsonObject<Entry, Result>(
  key: string,
  edit: (store: Record<string, Entry>) => Result,
): Promise<Result> {
  let result!: Result;
  await updateItemAsync(key, (raw) => {
    const store = parseStoredJsonObject<Entry>(raw);
    const before = JSON.stringify(store);
    result = edit(store);
    const after = JSON.stringify(store);
    if (after === before) return raw;
    return Object.keys(store).length ? after : null;
  });
  return result;
}

function parseStoredJsonObject<Entry>(raw: string | null): Record<string, Entry> {
  if (!raw) return {};
  try {
    const value: unknown = JSON.parse(raw);
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Entry> : {};
  } catch {
    return {};
  }
}

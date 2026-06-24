import type { BillingSummary } from './billingSummary';
import * as SecureStore from '@/native/secureStore';

const billingSummaryCacheKey = 'vex.billing.summary.v1';
const billingSummaryCacheSchemaVersion = 1;

type BillingSummaryCacheEntry = {
  savedAtMs: number;
  schemaVersion: number;
  summary: BillingSummary;
  userId: string;
};

type BillingSummaryCacheStore = Record<string, BillingSummaryCacheEntry>;

export async function loadCachedBillingSummary(userId: string): Promise<BillingSummary | null> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return null;
  }
  const store = await readBillingSummaryCacheStore();
  const entry = store[normalizedUserId];
  if (!isValidBillingSummaryCacheEntry(entry, normalizedUserId)) {
    if (entry) {
      delete store[normalizedUserId];
      await writeBillingSummaryCacheStore(store);
    }
    return null;
  }
  return entry.summary;
}

export async function saveCachedBillingSummary(userId: string, summary: BillingSummary): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  const store = await readBillingSummaryCacheStore();
  store[normalizedUserId] = {
    savedAtMs: Date.now(),
    schemaVersion: billingSummaryCacheSchemaVersion,
    summary,
    userId: normalizedUserId,
  };
  await writeBillingSummaryCacheStore(store);
}

async function readBillingSummaryCacheStore(): Promise<BillingSummaryCacheStore> {
  const raw = await SecureStore.getItemAsync(billingSummaryCacheKey).catch(() => null);
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

async function writeBillingSummaryCacheStore(store: BillingSummaryCacheStore): Promise<void> {
  if (Object.keys(store).length === 0) {
    await SecureStore.deleteItemAsync(billingSummaryCacheKey).catch(() => undefined);
    return;
  }
  await SecureStore.setItemAsync(billingSummaryCacheKey, JSON.stringify(store));
}

function isValidBillingSummaryCacheEntry(
  value: BillingSummaryCacheEntry | undefined,
  normalizedUserId: string,
): value is BillingSummaryCacheEntry {
  return Boolean(
    value
      && value.schemaVersion === billingSummaryCacheSchemaVersion
      && value.userId === normalizedUserId
      && value.summary
      && typeof value.summary.title === 'string'
      && typeof value.summary.subtitle === 'string'
      && Array.isArray(value.summary.plans),
  );
}

function normalizeUserId(userId: string): string {
  return userId.trim();
}

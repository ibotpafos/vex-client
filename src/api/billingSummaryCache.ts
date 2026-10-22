import type { BillingSummary } from './billingSummary';
import { updateStoredJsonObject } from '@/native/storedJsonObject';

const billingSummaryCacheKey = 'vex.billing.summary.v1';
const billingSummaryCacheSchemaVersion = 1;

type BillingSummaryCacheEntry = {
  savedAtMs: number;
  schemaVersion: number;
  summary: BillingSummary;
  userId: string;
};

export async function loadCachedBillingSummary(userId: string): Promise<BillingSummary | null> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return null;
  }
  return updateStoredJsonObject<BillingSummaryCacheEntry, BillingSummary | null>(billingSummaryCacheKey, (store) => {
    const entry = store[normalizedUserId];
    if (!isValidBillingSummaryCacheEntry(entry, normalizedUserId)) {
      delete store[normalizedUserId];
      return null;
    }
    return entry.summary;
  }).catch(() => null);
}

export async function saveCachedBillingSummary(userId: string, summary: BillingSummary): Promise<void> {
  const normalizedUserId = normalizeUserId(userId);
  if (!normalizedUserId) {
    return;
  }
  await updateStoredJsonObject<BillingSummaryCacheEntry, void>(billingSummaryCacheKey, (store) => {
    store[normalizedUserId] = {
      savedAtMs: Date.now(),
      schemaVersion: billingSummaryCacheSchemaVersion,
      summary,
      userId: normalizedUserId,
    };
  });
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

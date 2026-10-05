import type { VpnTrafficQuota } from '../api/types';

// Keep routine quota details in Settings. Home only needs an actionable warning.
export function shouldShowHomeTrafficQuota(quota: VpnTrafficQuota | null | undefined) {
  if (!quota || !hasQuotaLimit(quota.limitBytes)) return false;
  if (!Number.isFinite(quota.usedBytes) || quota.usedBytes < 0) return false;
  if (quota.limitReached) return true;
  return quotaRemainingBytes(quota.usedBytes, quota.limitBytes) / quota.limitBytes <= 0.10;
}

export function quotaRemainingBytes(usedBytes: number, limitBytes: number) {
  return Math.max(0, finitePositive(limitBytes) - finitePositive(usedBytes));
}

export function quotaProgress(usedBytes: number, limitBytes: number) {
  const safeLimit = finitePositive(limitBytes);
  return safeLimit === 0 ? 0 : Math.min(1, finitePositive(usedBytes) / safeLimit);
}

export function formatQuotaBytes(bytes: number) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  let value = finitePositive(bytes);
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const digits = unitIndex > 0 && value < 10 ? 1 : 0;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
}

export function hasQuotaLimit(limitBytes: number) {
  return Number.isFinite(limitBytes) && limitBytes > 0;
}

export function formatQuotaUsage(usedBytes: number, limitBytes: number) {
  return `${formatQuotaBytes(usedBytes)} / ${hasQuotaLimit(limitBytes) ? formatQuotaBytes(limitBytes) : 'Без лимита'}`;
}

export function quotaHeadline(usedBytes: number, limitBytes: number) {
  return hasQuotaLimit(limitBytes)
    ? `Осталось ${formatQuotaBytes(quotaRemainingBytes(usedBytes, limitBytes))}`
    : 'Безлимитный трафик';
}

export function formatQuotaResetAt(resetAt: string) {
  const parsed = new Date(resetAt);
  if (Number.isNaN(parsed.getTime())) return '1 числа';
  return new Intl.DateTimeFormat('ru-RU', {
    day: 'numeric',
    month: 'long',
    timeZone: 'Europe/Moscow',
  }).format(parsed);
}

function finitePositive(value: number) {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

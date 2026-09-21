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

export function formatQuotaUsage(usedBytes: number, limitBytes: number) {
  return `${formatQuotaBytes(usedBytes)} / ${formatQuotaBytes(limitBytes)}`;
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

export function normalizeEmailOTPCode(value: string): string {
  return value.replace(/[^0-9]/g, '').slice(0, 6);
}

export function emailOTPCells(value: string, length = 6): string[] {
  const normalized = normalizeEmailOTPCode(value).slice(0, length);
  return Array.from({ length }, (_, index) => normalized[index] ?? '');
}

export function isEmailOTPRequestCooldownError(error: unknown): boolean {
  return error instanceof Error
    && error.message.toLowerCase().includes('email code was already sent');
}

export function emailOTPRequestErrorMessage(error: unknown): string {
  if (isEmailOTPRequestCooldownError(error)) {
    return 'Код уже отправлен на email. Проверьте почту или запросите новый через минуту.';
  }
  return error instanceof Error ? error.message : 'Не удалось отправить код.';
}

export function isEmailOTPExpired(expiresAt: string | undefined, nowMs = Date.now()): boolean {
  if (!expiresAt) return false;
  const expiresAtMs = Date.parse(expiresAt);
  return Number.isFinite(expiresAtMs) && expiresAtMs <= nowMs;
}

export function isInvalidOrExpiredEmailOTPError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const message = error.message.toLowerCase();
  return message.includes('invalid or expired email code')
    || message.includes('неверный код')
    || message.includes('код истек')
    || message.includes('код истёк');
}

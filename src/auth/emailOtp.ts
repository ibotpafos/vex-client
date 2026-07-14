export function normalizeEmailOTPCode(value: string): string {
  return value.replace(/[^0-9]/g, '').slice(0, 6);
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

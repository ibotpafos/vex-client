export const entitlementCacheTtlMs = 5 * 60_000;
export const locationsCacheTtlMs = 15 * 60_000;
export const devicesCacheTtlMs = 5 * 60_000;

export type VpnQueryCacheFreshness = 'fresh' | 'stale' | 'expired';

export function vpnQueryCacheFreshness(
  savedAtMs: number,
  nowMs: number,
  ttlMs: number,
): VpnQueryCacheFreshness {
  const ageMs = nowMs - savedAtMs;
  if (!Number.isFinite(savedAtMs) || savedAtMs <= 0 || ageMs < 0 || ageMs > ttlMs * 2) {
    return 'expired';
  }
  return ageMs > ttlMs ? 'stale' : 'fresh';
}

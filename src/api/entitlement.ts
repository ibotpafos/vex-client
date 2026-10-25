import type { Entitlement } from './types';

export type EntitlementLike = Partial<Pick<Entitlement, 'active' | 'vpnAccess'>>;

export function hasPaidEntitlement<T extends EntitlementLike>(
  item: T | null | undefined,
): item is T {
  return Boolean(item?.vpnAccess || item?.active);
}

import { jsonRequest } from './client';
import { hasPaidEntitlement as matchesPaidEntitlement } from './entitlement';
import { type Entitlement } from './types';
import { type EntitlementDTO } from './dto';

export function hasPaidEntitlement(item: Entitlement | null | undefined): item is Entitlement {
  return matchesPaidEntitlement(item);
}

export async function entitlement(accessToken: string, signal?: AbortSignal): Promise<Entitlement> {
  const item = await jsonRequest<EntitlementDTO>('/v1/billing/entitlement', {
    accessToken,
    suppressErrorLog: true,
    ...(signal ? { signal } : {}),
  });
  return parseEntitlement(item);
}

export function parseEntitlement(item: EntitlementDTO): Entitlement {
  return {
    active: Boolean(item.active),
    planId: item.plan_id || undefined,
    displayName: item.display_name || undefined,
    accountStatus: item.account_status || undefined,
    subscriptionTitle: item.subscription_title || undefined,
    subscriptionSubtitle: item.subscription_subtitle || undefined,
    remainingText: item.remaining_text || undefined,
    status: item.status || undefined,
    tier: item.tier || undefined,
    currentPeriodEnd: item.current_period_end || undefined,
    effectiveExpiresAt: item.effective_expires_at || undefined,
    vpnAccess: Boolean(item.vpn_access),
  };
}

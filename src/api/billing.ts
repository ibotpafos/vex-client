import { jsonRequest, vexApiBaseUrl } from './client';
import { buildBillingSummary } from './billingSummary';
import {
  type Entitlement,
  type BillingSummary,
  type CheckoutSession,
  type BillingPortalSession,
  type ServerBillingPlan,
  type ServerCheckoutSession,
  type ServerEntitlement,
  type ServerPortalSession,
} from './types';

export type CheckoutSessionOptions = {
  failedUrl?: string;
  returnUrl?: string;
};

export function hasPaidEntitlement(item: Entitlement | null | undefined): item is Entitlement {
  return Boolean(item?.vpnAccess || item?.active);
}

export async function entitlement(accessToken: string): Promise<Entitlement> {
  const item = await jsonRequest<ServerEntitlement>('/v1/billing/entitlement', {
    accessToken,
    suppressErrorLog: true,
  });
  return parseEntitlement(item);
}

export async function billingSummary(accessToken: string): Promise<BillingSummary> {
  const [plans, currentEntitlement] = await Promise.all([
    billingPlans().catch((): ServerBillingPlan[] => []),
    entitlement(accessToken).catch((): null => null),
  ]);
  return buildBillingSummary(plans, currentEntitlement);
}

async function billingPlans(): Promise<ServerBillingPlan[]> {
  return jsonRequest<ServerBillingPlan[]>('/v1/billing/plans', {
    suppressErrorLog: true,
    timeout: 75000,
  });
}

export async function checkoutSession(accessToken: string, plan: { id: string; provider?: string }, options: CheckoutSessionOptions = {}): Promise<CheckoutSession> {
  const item = await jsonRequest<ServerCheckoutSession>('/v1/billing/checkout-session', {
    method: 'POST',
    accessToken,
    idempotencyKey: `android-checkout-${plan.id}-${Date.now()}`,
    body: {
      plan_id: plan.id,
      provider: plan.provider || 'platega',
      return_url: options.returnUrl || vexApiBaseUrl,
      failed_url: options.failedUrl || vexApiBaseUrl,
    },
  });
  return parseCheckoutSession(item);
}

export async function cancelSubscription(accessToken: string): Promise<Entitlement> {
  const item = await jsonRequest<ServerEntitlement>('/v1/billing/subscription/cancel', {
    method: 'POST',
    accessToken,
    idempotencyKey: `subscription-cancel-${Date.now()}`,
  });
  return parseEntitlement(item);
}

export async function portalSession(accessToken: string): Promise<BillingPortalSession> {
  const item = await jsonRequest<ServerPortalSession>('/v1/billing/portal-session', {
    accessToken,
    suppressErrorLog: true,
  });
  return {
    id: item.id || '',
    provider: item.provider || 'manual',
    url: item.url || '',
    createdAt: item.created_at || undefined,
  };
}

export function parseCheckoutSession(item: ServerCheckoutSession): CheckoutSession {
  return {
    id: item.id,
    planId: item.plan_id,
    provider: item.provider,
    url: item.url,
    status: item.status,
  };
}

export function parseEntitlement(item: ServerEntitlement): Entitlement {
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

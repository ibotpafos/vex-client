export type BillingEntitlement = {
  active: boolean;
  planId?: string;
  displayName?: string;
  accountStatus?: string;
  subscriptionTitle?: string;
  subscriptionSubtitle?: string;
  remainingText?: string;
  status?: string;
  tier?: string;
  currentPeriodEnd?: string;
  effectiveExpiresAt?: string;
  vpnAccess: boolean;
};

export type BillingPlanOption = {
  id: string;
  name: string;
  provider: string;
  meta: string;
  action: string;
  current: boolean;
  disabled: boolean;
  interval: string;
  durationMonths: number;
};

export type BillingSummary = {
  title: string;
  subtitle: string;
  emptyMessage: string;
  entitlementStatus: 'active' | 'inactive' | 'unknown';
  currentPlan?: BillingPlanOption;
  currentPeriodEnd?: string;
  effectiveExpiresAt?: string;
  remainingText?: string;
  status?: string;
  plans: BillingPlanOption[];
};

export type BillingSummaryCopy = Pick<BillingSummary, 'title' | 'subtitle'>;

export type BillingPlanSource = {
  id: string;
  name?: string;
  provider?: string;
  amount_cents: number;
  currency: string;
  interval: string;
  device_limit: number;
  tier: string;
  status: string;
};

const fallbackBillingPlans: BillingPlanSource[] = [
  {
    id: 'basic_monthly',
    name: 'Базовый',
    provider: 'platega',
    amount_cents: 19900,
    currency: 'RUB',
    interval: 'monthly',
    device_limit: 1,
    tier: 'basic',
    status: 'active',
  },
  {
    id: 'pro_monthly',
    name: 'Pro',
    provider: 'platega',
    amount_cents: 49900,
    currency: 'RUB',
    interval: 'monthly',
    device_limit: 3,
    tier: 'pro',
    status: 'active',
  },
  {
    id: 'family_monthly',
    name: 'Team',
    provider: 'platega',
    amount_cents: 149900,
    currency: 'RUB',
    interval: 'monthly',
    device_limit: 10,
    tier: 'team',
    status: 'active',
  },
];

export function buildBillingSummary(
  plans: BillingPlanSource[],
  currentEntitlement: BillingEntitlement | null,
): BillingSummary {
  const sourcePlans = plans.length > 0 ? plans : fallbackBillingPlans;
  const activePlans = sourcePlans
    .filter((plan) => plan.status === 'active')
    .sort((a, b) => a.amount_cents - b.amount_cents || a.id.localeCompare(b.id));
  const currentPlan = currentBillingPlan(activePlans, currentEntitlement);
  const hasActiveEntitlement = hasPaidBillingEntitlement(currentEntitlement);
  const entitlementStatus = currentEntitlement === null
    ? 'unknown'
    : hasActiveEntitlement
      ? 'active'
      : 'inactive';

  const planOptions = activePlans.map((plan) => {
    const current = Boolean(currentPlan && billingPlansMatch(plan, currentPlan));
    return {
      id: plan.id,
      provider: plan.provider || 'platega',
      name: plan.name || mobilePlanLabel(plan.tier, plan.id),
      meta: `${mobilePlanPrice(plan)} · ${mobileDeviceLimitText(plan.device_limit)}`,
      action: entitlementStatus === 'unknown' ? 'Проверяем' : mobilePlanActionText(plan, currentPlan, hasActiveEntitlement),
      current,
      disabled: current || entitlementStatus === 'unknown',
      interval: plan.interval,
      durationMonths: billingDurationMonths(plan.interval),
    };
  });

  return {
    title: entitlementStatus === 'active'
      ? 'Управление подпиской'
      : entitlementStatus === 'unknown'
        ? 'Проверяем подписку'
        : 'Выберите подписку',
    subtitle: entitlementStatus === 'active'
      ? currentPlan
        ? 'Текущий тариф отмечен. Можно перейти на другой.'
        : 'Подписка активна. Можно перейти на один из доступных тарифов.'
      : entitlementStatus === 'unknown'
        ? 'Не удалось подтвердить текущий тариф. Обновите экран через несколько секунд.'
        : 'Оплата откроется в браузере.',
    emptyMessage: 'Активные тарифы сейчас недоступны.',
    entitlementStatus,
    currentPlan: planOptions.find((plan) => plan.current),
    currentPeriodEnd: currentEntitlement?.currentPeriodEnd,
    effectiveExpiresAt: currentEntitlement?.effectiveExpiresAt,
    remainingText: currentEntitlement?.remainingText,
    status: currentEntitlement?.status,
    plans: planOptions,
  };
}

export function billingSummaryFallbackCopy(isLoading: boolean): BillingSummaryCopy {
  return isLoading
    ? {
      title: 'Проверяем подписку',
      subtitle: 'Проверяем текущий тариф и доступные планы.',
    }
    : {
      title: 'Выберите подписку',
      subtitle: 'Оплата откроется в браузере.',
    };
}

function hasPaidBillingEntitlement(item: BillingEntitlement | null | undefined): item is BillingEntitlement {
  return Boolean(item?.vpnAccess || item?.active);
}

function currentBillingPlan(plans: BillingPlanSource[], entitlementState: BillingEntitlement | null): BillingPlanSource | null {
  if (!hasPaidBillingEntitlement(entitlementState)) {
    return null;
  }
  const planId = (entitlementState.planId || '').toLowerCase();
  const tier = (entitlementState.tier || '').toLowerCase();
  return plans.find((plan) => plan.id.toLowerCase() === planId)
    ?? plans.find((plan) => plan.tier.toLowerCase() === tier && tier)
    ?? plans.find((plan) => tier && plan.id.toLowerCase().includes(tier))
    ?? null;
}

function billingPlansMatch(plan: BillingPlanSource, currentPlan: BillingPlanSource): boolean {
  return plan.id === currentPlan.id;
}

function mobilePlanActionText(plan: BillingPlanSource, currentPlan: BillingPlanSource | null, hasCurrent: boolean): string {
  if (currentPlan && billingPlansMatch(plan, currentPlan)) {
    return 'Текущий';
  }
  if (!hasCurrent) {
    return 'Купить';
  }
  if (!currentPlan) {
    return 'Сменить';
  }
  if (plan.amount_cents > currentPlan.amount_cents) {
    return 'Обновить';
  }
  if (plan.amount_cents < currentPlan.amount_cents) {
    return 'Перейти';
  }
  return 'Сменить';
}

function mobilePlanPrice(plan: BillingPlanSource): string {
  const currency = (plan.currency || 'RUB').toUpperCase();
  const value = (plan.amount_cents || 0) / 100;
  const price = new Intl.NumberFormat('ru-RU', {
    style: 'currency',
    currency,
    maximumFractionDigits: Number.isInteger(value) ? 0 : 2,
  }).format(value);
  return `${price}/${mobilePlanIntervalText(plan.interval)}`;
}

export function billingDurationMonths(interval: string): number {
  switch (interval.toLowerCase()) {
    case 'quarter':
    case 'quarterly':
      return 3;
    case 'semiannual':
      return 6;
    case 'year':
    case 'yearly':
    case 'annual':
      return 12;
    default:
      return 1;
  }
}

export function billingDurationLabel(months: number): string {
  if (months === 1) return '1 месяц';
  if (months >= 2 && months <= 4) return `${months} месяца`;
  return `${months} месяцев`;
}

function mobilePlanIntervalText(interval: string): string {
  switch (interval.toLowerCase()) {
    case 'year':
    case 'yearly':
    case 'annual':
      return 'год';
    case 'week':
    case 'weekly':
      return 'нед.';
    case 'day':
    case 'daily':
      return 'день';
    default:
      return 'мес.';
  }
}

function mobileDeviceLimitText(limit: number): string {
  const safeLimit = Math.max(0, limit);
  const mod10 = safeLimit % 10;
  const mod100 = safeLimit % 100;
  if (mod10 === 1 && mod100 !== 11) {
    return `${safeLimit} устройство`;
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return `${safeLimit} устройства`;
  }
  return `${safeLimit} устройств`;
}

function mobilePlanLabel(...values: string[]): string {
  for (const value of values) {
    const normalized = value.trim().replaceAll('_', '-').split('-')[0];
    if (normalized) {
      return normalized.charAt(0).toUpperCase() + normalized.slice(1);
    }
  }
  return 'Pro';
}

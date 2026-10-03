import type { Entitlement } from '../api/types';

const renewalWindowMs = 3 * 24 * 60 * 60 * 1000;

// Presentation only: never starts checkout, changes access, or schedules a new
// notification. Unknown/stale entitlement must not masquerade as a trial end.
export function subscriptionRenewalPresentation(entitlement: Entitlement | null, now = Date.now()) {
  if (!entitlement || !Number.isFinite(now)) return null;
  const hasAccess = entitlement.vpnAccess || entitlement.active;
  const expiryText = entitlement.effectiveExpiresAt ?? entitlement.currentPeriodEnd;
  const expiresAt = expiryText ? Date.parse(expiryText) : NaN;
  const expired = expiresAt <= now;
  if (!hasAccess) {
    return {
      title: expired ? 'Доступ к VPN завершён' : 'Доступ к VPN не активен',
      message: 'Проверьте подписку в личном кабинете или обратитесь в поддержку. Тарифы и цена — на сайте VEX.',
      action: 'Продлить VPN',
    };
  }
  if (!Number.isFinite(expiresAt)) return null;
  if (hasAccess && expired) return null; // May be a stale/offline snapshot.
  const isTrial = entitlement.status === 'trialing';
  if (hasAccess && !isTrial && expiresAt - now > renewalWindowMs) return null;
  const date = new Date(expiresAt).toLocaleString('ru-RU', {
    day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit',
  });
  return {
    title: 'Доступ к VPN',
    message: `Доступ до ${date}. Тарифы и цена — в личном кабинете.`,
    action: 'Продлить VPN',
  };
}

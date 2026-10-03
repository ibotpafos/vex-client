import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { subscriptionRenewalPresentation } from '../src/screens/subscription-renewal-presentation.ts';

const now = Date.parse('2026-10-02T00:00:00Z');
const active = {active: true, vpnAccess: true, status: 'active', planId: 'basic_monthly'};

test('unknown entitlement never becomes an expired or trial account', () => {
  assert.equal(subscriptionRenewalPresentation(null, now), null);
});
test('finite access shows actual server expiry and never a fabricated price or trial duration', () => {
  const result = subscriptionRenewalPresentation({...active, effectiveExpiresAt: '2026-10-03T12:30:00Z'}, now);
  assert.equal(result.action, 'Продлить VPN');
  assert.match(result.message, /3 октября/);
  assert.doesNotMatch(JSON.stringify(result), /199|499|3 дня|Бесплатно/);
});
test('effective expiry takes precedence over the billing period, including grace', () => {
  const result = subscriptionRenewalPresentation({...active, currentPeriodEnd: '2026-10-01T00:00:00Z', effectiveExpiresAt: '2026-10-04T00:00:00Z'}, now);
  assert.match(result.message, /4 октября/);
  assert.doesNotMatch(result.title, /заверш/);
});
test('confirmed inactive access explains renewal instead of a connection fault', () => {
  const result = subscriptionRenewalPresentation({...active, active: false, vpnAccess: false, effectiveExpiresAt: '2026-10-01T00:00:00Z'}, now);
  assert.equal(result.title, 'Доступ к VPN завершён');
  assert.match(result.message, /подписку/);
});
test('inactive future-dated entitlement never promises working access', () => {
  const result = subscriptionRenewalPresentation({...active, active: false, vpnAccess: false, effectiveExpiresAt: '2026-10-05T00:00:00Z'}, now);
  assert.equal(result.title, 'Доступ к VPN не активен');
  assert.doesNotMatch(result.message, /Доступ до/);
});
test('confirmed inactive account without expiry still has a renewal path, not an invented trial end', () => {
  const result = subscriptionRenewalPresentation({active: false, vpnAccess: false}, now);
  assert.equal(result.title, 'Доступ к VPN не активен');
  assert.equal(result.action, 'Продлить VPN');
  assert.doesNotMatch(result.message, /Доступ до|заверш|дня/);
});
test('permanent, invalid or contradictory expiry does not invent a deadline', () => {
  for (const value of [active, {...active, effectiveExpiresAt: 'garbage'}, {...active, effectiveExpiresAt: '2026-10-01T00:00:00Z'}]) {
    assert.equal(subscriptionRenewalPresentation(value, now), null);
  }
});
test('healthy paid access far from expiry has no home upsell; trial and near expiry do', () => {
  assert.equal(subscriptionRenewalPresentation({...active, effectiveExpiresAt: '2026-11-01T00:00:00Z'}, now), null);
  assert.ok(subscriptionRenewalPresentation({...active, status: 'trialing', effectiveExpiresAt: '2026-10-07T00:00:00Z'}, now));
});
test('Android renewal card is wired to existing website path, without token URLs or automatic checkout', () => {
  const home = readFileSync(new URL('../src/screens/home-screen.tsx', import.meta.url), 'utf8');
  const card = readFileSync(new URL('../src/components/subscription-renewal-card.tsx', import.meta.url), 'utf8');
  const context = readFileSync(new URL('../src/vpn/useVpnConnection.ts', import.meta.url), 'utf8');
  const settings = readFileSync(new URL('../src/screens/settings-screen.tsx', import.meta.url), 'utf8');
  assert.match(home, /Platform\.OS === 'android'/);
  assert.match(home, /SubscriptionRenewalCard/);
  assert.match(home, /<HomeBody>[\s\S]*<LocationHomeHero/);
  assert.match(home, /function HomeBody[\s\S]*Platform\.OS === 'android'[\s\S]*<ScrollView/);
  assert.match(context, /return \{[\s\S]*entitlementState,/);
  assert.match(card, /vexWebsite\.dashboard\(\)/);
  assert.match(card, /vexWebsite\.support\(\)/);
  assert.match(card, /Не удалось открыть сайт VEX/);
  assert.doesNotMatch(card, /accessToken|refreshToken|disconnect|useEffect|checkoutSession|199/);
  assert.match(settings, /Продлить VPN/);
});

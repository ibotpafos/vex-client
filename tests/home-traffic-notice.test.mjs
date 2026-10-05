import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { shouldShowHomeTrafficQuota } from '../src/components/traffic-quota-presentation.ts';

const quota = (usedBytes, limitBytes = 1000, limitReached = false) => ({ usedBytes, limitBytes, limitReached });

test('home quota warning starts at exactly 10% remaining', () => {
  assert.equal(shouldShowHomeTrafficQuota(quota(899)), false);
  assert.equal(shouldShowHomeTrafficQuota(quota(900)), true);
  assert.equal(shouldShowHomeTrafficQuota(quota(901)), true);
  assert.equal(shouldShowHomeTrafficQuota(quota(1000)), true);
  assert.equal(shouldShowHomeTrafficQuota(quota(1100)), true);
  assert.equal(shouldShowHomeTrafficQuota(quota(13)), false);
});
test('missing, unlimited and invalid measurements do not invent low traffic', () => {
  for (const value of [null, undefined, quota(1000, 0), quota(1000, -1), quota(1000, NaN), quota(1000, Infinity), quota(NaN), quota(Infinity), quota(-1), quota(NaN, 1000, true), quota(-1, 1000, true)]) {
    assert.equal(shouldShowHomeTrafficQuota(value), false);
  }
});
test('server-confirmed reached limit stays actionable despite lagging used bytes', () => {
  assert.equal(shouldShowHomeTrafficQuota(quota(0, 1000, true)), true);
});
test('only Home is gated; full quota details remain in Settings', () => {
  const home = readFileSync(new URL('../src/screens/home-screen.tsx', import.meta.url), 'utf8');
  const settings = readFileSync(new URL('../src/screens/settings-screen.tsx', import.meta.url), 'utf8');
  assert.match(home, /trafficQuota && shouldShowHomeTrafficQuota\(trafficQuota\)/);
  assert.match(settings, /formatQuotaUsage\(trafficQuota\.usedBytes, trafficQuota\.limitBytes\)/);
  assert.doesNotMatch(settings, /shouldShowHomeTrafficQuota/);
});

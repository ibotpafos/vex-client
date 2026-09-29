import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { VpnTrafficQuota } from '@/api/vexApi';
import {
  formatQuotaBytes,
  formatQuotaResetAt,
  formatQuotaUsage,
  hasQuotaLimit,
  quotaHeadline,
  quotaProgress,
} from '@/components/traffic-quota-presentation';

export function TrafficQuotaSummary({ quota }: { quota: VpnTrafficQuota }) {
  const limited = hasQuotaLimit(quota.limitBytes);
  const headline = quotaHeadline(quota.usedBytes, quota.limitBytes);
  const progress = quotaProgress(quota.usedBytes, quota.limitBytes);
  const usage = limited
    ? formatQuotaUsage(quota.usedBytes, quota.limitBytes)
    : `Использовано ${formatQuotaBytes(quota.usedBytes)}`;

  return (
    <View
      accessibilityLabel={`${headline}. ${usage}`}
      style={styles.card}
      testID="home-traffic-quota"
    >
      <View style={styles.header}>
        <Text style={styles.remaining}>{headline}</Text>
        <Text style={styles.usage}>{usage}</Text>
      </View>
      {limited ? (
        <View style={styles.track}>
          <View style={[styles.progress, quota.limitReached && styles.progressReached, { width: `${progress * 100}%` }]} />
        </View>
      ) : null}
      {limited || quota.multiplier > 1 ? (
        <View style={styles.footer}>
          {limited ? <Text style={styles.meta}>Сброс {formatQuotaResetAt(quota.resetAt)}</Text> : null}
          {quota.multiplier > 1 ? <Text style={styles.meta}>Мобильный трафик ×{quota.multiplier}</Text> : null}
        </View>
      ) : null}
      {limited && quota.limitReached ? (
        <Text accessibilityRole="alert" style={styles.warning}>
          Лимит достигнут · скорость {quota.effectiveRateLimitMbps ?? 1} Мбит/с
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: 'rgba(3, 25, 31, 0.72)',
    borderColor: 'rgba(154, 229, 237, 0.24)',
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
    gap: 7,
    paddingHorizontal: 13,
    paddingVertical: 11,
  },
  footer: { flexDirection: 'row', justifyContent: 'space-between' },
  header: { alignItems: 'center', flexDirection: 'row', gap: 10, justifyContent: 'space-between' },
  meta: { color: 'rgba(205, 229, 233, 0.72)', fontSize: 11, fontWeight: '700' },
  progress: { backgroundColor: '#62E6B5', borderRadius: 999, height: '100%' },
  progressReached: { backgroundColor: '#F3C969' },
  remaining: { color: '#F4FCFD', fontSize: 14, fontWeight: '800' },
  track: { backgroundColor: 'rgba(185, 227, 232, 0.14)', borderRadius: 999, height: 6, overflow: 'hidden' },
  usage: { color: 'rgba(226, 241, 244, 0.82)', fontSize: 12, fontVariant: ['tabular-nums'], fontWeight: '700' },
  warning: { color: '#F3C969', fontSize: 11, fontWeight: '800' },
});

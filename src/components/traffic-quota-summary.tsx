import { vexTheme } from '@/ui/vex-theme';
import { StyleSheet, Text, View } from 'react-native';
import React from 'react';

import type { VpnTrafficQuota } from '@/api/vexApi';
import {
  formatQuotaBytes,
  formatQuotaResetAt,
  formatQuotaUsage,
  hasQuotaLimit,
  quotaHeadline,
  quotaProgress,
} from '@/components/traffic-quota-presentation';

export const TrafficQuotaSummary = React.memo(function TrafficQuotaSummary({ quota }: { quota: VpnTrafficQuota }) {
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
});

const styles = StyleSheet.create({
  card: {
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  footer: { flexDirection: 'row', justifyContent: 'space-between' },
  header: { alignItems: 'center', flexDirection: 'row', gap: 12, justifyContent: 'space-between' },
  meta: { color: vexTheme.colors.textMuted, fontSize: 12, fontWeight: '500' },
  progress: { backgroundColor: vexTheme.colors.success, borderRadius: 999, height: '100%' },
  progressReached: { backgroundColor: vexTheme.colors.warning },
  remaining: { color: vexTheme.colors.text, fontSize: 14, fontWeight: '600' },
  track: { backgroundColor: vexTheme.colors.surfaceRaised, borderRadius: 999, height: 6, overflow: 'hidden' },
  usage: { color: vexTheme.colors.textSecondary, fontSize: 12, fontVariant: ['tabular-nums'], fontWeight: '500' },
  warning: { color: vexTheme.colors.warning, fontSize: 12, fontWeight: '500' },
});

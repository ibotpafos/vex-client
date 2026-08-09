import React from 'react';
import { View, Text } from 'react-native';
import { ArrowDown, ArrowUp } from 'lucide-react-native';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { useVpnTrafficStats } from '@/vpn/vpnTrafficStatsStore';
import { formatBytes } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';
import { vexTheme } from '@/ui/vex-theme';
import { trafficSessionLabel } from './traffic-summary';

export const TrafficStats = React.memo(function TrafficStats() {
  useRenderProfilerMark('TrafficStats');
  const { rxBytes, txBytes } = useVpnTrafficStats();
  return (
    <View style={styles.trafficStats}>
      <View style={styles.trafficCard} accessibilityLabel={`${trafficSessionLabel('received')}: ${formatBytes(rxBytes)}`}>
        <View style={styles.trafficCardHeader}>
          <View style={styles.trafficDirectionIcon}>
            <ArrowDown color={vexTheme.colors.accent} size={24} strokeWidth={2.6} />
          </View>
          <Text style={styles.trafficLabel}>Получено</Text>
        </View>
        <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(rxBytes)}</Text>
      </View>
      <View style={styles.trafficCard} accessibilityLabel={`${trafficSessionLabel('sent')}: ${formatBytes(txBytes)}`}>
        <View style={styles.trafficCardHeader}>
          <View style={styles.trafficDirectionIcon}>
            <ArrowUp color={vexTheme.colors.accent} size={24} strokeWidth={2.6} />
          </View>
          <Text style={styles.trafficLabel}>Отправлено</Text>
        </View>
        <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(txBytes)}</Text>
      </View>
    </View>
  );
});

import React from 'react';
import { View, Text } from 'react-native';
import { ArrowDown, ArrowUp } from 'lucide-react-native';
import Svg, { Polyline } from 'react-native-svg';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { useVpnTrafficStats } from '@/vpn/vpnTrafficStatsStore';
import { formatBytes } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';
import { vexTheme } from '@/ui/vex-theme';

export const TrafficStats = React.memo(function TrafficStats() {
  useRenderProfilerMark('TrafficStats');
  const { rxBytes, txBytes } = useVpnTrafficStats();
  return (
    <View style={styles.trafficStats} accessibilityLabel={`Трафик. Получено ${formatBytes(rxBytes)}, отправлено ${formatBytes(txBytes)}`}>
      <View style={styles.trafficCard}>
        <View style={styles.trafficCardHeader}>
          <View style={styles.trafficDirectionBadge}>
            <ArrowDown color={vexTheme.colors.accent} size={19} strokeWidth={2.5} />
          </View>
          <Text style={styles.trafficLabel}>Получено</Text>
        </View>
        <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(rxBytes)}</Text>
        <TrafficSparkline reversed={false} />
      </View>
      <View style={styles.trafficCard}>
        <View style={styles.trafficCardHeader}>
          <View style={styles.trafficDirectionBadge}>
            <ArrowUp color={vexTheme.colors.accent} size={19} strokeWidth={2.5} />
          </View>
          <Text style={styles.trafficLabel}>Отправлено</Text>
        </View>
        <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(txBytes)}</Text>
        <TrafficSparkline reversed />
      </View>
    </View>
  );
});

function TrafficSparkline({ reversed }: { reversed: boolean }) {
  const points = reversed
    ? '2,27 22,20 42,24 62,15 82,20 102,23 122,16 142,4'
    : '2,27 22,20 42,24 62,15 82,20 102,23 122,16 142,4';
  return (
    <Svg aria-label="Динамика трафика" height={28} style={styles.trafficSparkline} viewBox="0 0 144 32" width="100%">
      <Polyline fill="none" points={points} stroke={vexTheme.colors.accent} strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.4} />
    </Svg>
  );
}

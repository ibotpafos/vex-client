import React from 'react';
import { View, Text } from 'react-native';
import { ArrowDown, ArrowUp } from 'lucide-react-native';
import { formatBytes } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';

export interface TrafficStatsProps {
  rxBytes: number;
  txBytes: number;
}

export function TrafficStats({ rxBytes, txBytes }: TrafficStatsProps) {
  return (
    <View style={styles.trafficStats} accessibilityLabel={`Трафик. Получено ${formatBytes(rxBytes)}, отправлено ${formatBytes(txBytes)}`}>
      <View style={styles.trafficItem}>
        <Text style={styles.trafficLabel}>Получено</Text>
        <View style={styles.trafficValueRow}>
          <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(rxBytes)}</Text>
          <View style={styles.trafficDirectionBadge}>
            <ArrowDown color="#22D3EE" size={13} strokeWidth={3} />
          </View>
        </View>
      </View>
      <View style={styles.trafficDivider} />
      <View style={styles.trafficItem}>
        <Text style={styles.trafficLabel}>Отправлено</Text>
        <View style={styles.trafficValueRow}>
          <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(txBytes)}</Text>
          <View style={styles.trafficDirectionBadge}>
            <ArrowUp color="#22D3EE" size={13} strokeWidth={3} />
          </View>
        </View>
      </View>
    </View>
  );
}

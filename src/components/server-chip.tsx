import React from 'react';
import { Pressable, View, Text } from 'react-native';
import { MapPin, Gauge, ChevronRight } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { serverLocationLabel } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';

export interface ServerChipProps {
  disabled: boolean;
  isAutoMode: boolean;
  latencyText: string;
  location?: VpnLocation;
  onPress: () => void;
}

export const ServerChip = React.memo(function ServerChip({
  disabled,
  isAutoMode,
  latencyText,
  location,
  onPress,
}: ServerChipProps) {
  useRenderProfilerMark('ServerChip');
  const locationLabel = location ? serverLocationLabel(location) : 'Не выбран';
  const serverLabel = isAutoMode && location ? `Авто: ${locationLabel}` : locationLabel;
  const visibleServerLabel = locationLabel;
  return (
    <Pressable
      disabled={disabled}
      onPress={onPress}
      style={[styles.serverChip, disabled && styles.serverChipDisabled]}
      accessibilityRole="button"
      accessibilityLabel={`Выбрать сервер. Сейчас ${serverLabel}, задержка ${latencyText}`}
    >
      <View style={styles.serverChipIcon}>
        <MapPin color="#22D3EE" size={18} strokeWidth={2.5} />
      </View>
      <View style={styles.serverChipCopy}>
        <Text style={styles.serverChipCaption}>{isAutoMode ? 'Сервер · авто' : 'Сервер'}</Text>
        <Text numberOfLines={1} style={styles.serverChipLabel}>
          {visibleServerLabel}
        </Text>
      </View>
      <View style={styles.serverLatencyPill}>
        <Gauge color="#B9FBFF" size={13} strokeWidth={2.6} />
        <Text numberOfLines={1} style={styles.serverLatencyText}>{latencyText}</Text>
      </View>
      <ChevronRight color="#78969C" size={19} strokeWidth={2.6} />
    </Pressable>
  );
});

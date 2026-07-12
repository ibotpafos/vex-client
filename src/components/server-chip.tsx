import React from 'react';
import { View, Text } from 'react-native';
import { MapPin, Gauge, ChevronRight } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { serverLocationLabel } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';
import { VexPressable } from '@/ui/vex-ui';
import { vexTheme } from '@/ui/vex-theme';

export interface ServerChipProps {
  disabled: boolean;
  isAutoMode: boolean;
  latencyText: string;
  location?: VpnLocation;
  onPress: (visibleLatencyText: string) => void;
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
    <VexPressable
      disabled={disabled}
      onPress={() => onPress(latencyText)}
      style={[styles.serverChip, disabled && styles.serverChipDisabled]}
      hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.4)' }}
      title="Выбрать сервер подключения"
      accessibilityRole="button"
      accessibilityLabel={`Выбрать сервер. Сейчас ${serverLabel}, задержка ${latencyText}`}
    >
      <View style={styles.serverChipIcon}>
        <MapPin color={vexTheme.colors.accent} size={18} strokeWidth={2.5} />
      </View>
      <View style={styles.serverChipCopy}>
        <Text style={styles.serverChipCaption}>{isAutoMode ? 'Сервер · авто' : 'Сервер'}</Text>
        <Text numberOfLines={1} style={styles.serverChipLabel}>
          {visibleServerLabel}
        </Text>
      </View>
      <View style={styles.serverLatencyPill}>
        <Gauge color={vexTheme.colors.accentStrong} size={13} strokeWidth={2.6} />
        <Text numberOfLines={1} style={styles.serverLatencyText}>{latencyText}</Text>
      </View>
      <ChevronRight color={vexTheme.colors.textMuted} size={19} strokeWidth={2.6} />
    </VexPressable>
  );
});

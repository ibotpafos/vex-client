import React from 'react';
import { View, Text } from 'react-native';
import { Check, Circle, Gauge } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { serverLocationLabel } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';
import { VexPressable } from '@/ui/vex-ui';
import { vexTheme } from '@/ui/vex-theme';
import { availableNodeCountText } from '../screens/country-groups';
import { CountryIsland } from './country-island';

export interface ServerChipProps {
  availableNodeCount?: number;
  disabled: boolean;
  isAutoMode: boolean;
  isSelected?: boolean;
  latencyText: string;
  location?: VpnLocation;
  onPress: (visibleLatencyText: string) => void;
}

export const ServerChip = React.memo(function ServerChip({
  availableNodeCount = 0,
  disabled,
  isAutoMode,
  isSelected = true,
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
      style={[styles.serverChip, isSelected && styles.serverChipSelected, disabled && styles.serverChipDisabled]}
      hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.4)' }}
      title="Выбрать сервер подключения"
      accessibilityRole="button"
      accessibilityLabel={`Открыть серверы: ${serverLabel}, ${availableNodeCountText(availableNodeCount)}, задержка ${latencyText}`}
    >
      <View style={styles.serverChipCountryIsland}>
        <CountryIsland countryCode={location?.countryCode} selected={isSelected} />
      </View>
      <View style={styles.serverChipFlag}>
        <Text style={styles.serverChipFlagText}>{location?.flagEmoji ?? '🌐'}</Text>
      </View>
      <View style={styles.serverChipCopy}>
        <Text numberOfLines={1} style={styles.serverChipLabel}>
          {visibleServerLabel}
        </Text>
        <Text style={styles.serverChipCaption}>{availableNodeCountText(availableNodeCount)} · {availableNodeCount > 0 ? 'доступно' : 'нет доступных'}</Text>
      </View>
      <View style={styles.serverLatencyPill}>
        <Gauge color={vexTheme.colors.accentStrong} size={13} strokeWidth={2.6} />
        <Text numberOfLines={1} style={styles.serverLatencyText}>{latencyText}</Text>
      </View>
      {isSelected ? (
        <View style={styles.serverSelectedIcon}>
          <Check color={vexTheme.colors.accentInk} size={16} strokeWidth={3.3} />
        </View>
      ) : <Circle color={vexTheme.colors.textMuted} size={27} strokeWidth={2.3} />}
    </VexPressable>
  );
});

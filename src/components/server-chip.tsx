import React, { useRef } from 'react';
import { View, Text, StyleSheet, type GestureResponderEvent } from 'react-native';
import { Check, Circle, Gauge, Globe2 } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { homeLocationCardLabel } from '../screens/home-location-previews';
import { styles } from '../screens/home-screen.styles';
import { VexPressable } from '@/ui/vex-ui';
import { vexTheme } from '@/ui/vex-theme';
import { availableNodeCountText } from '../screens/country-groups';
import { CountryIsland } from './country-island';
import { isServerChipTap, type TouchPoint } from '../screens/server-chip-interaction';

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
  const touchStartRef = useRef<TouchPoint | null>(null);
  const touchMovedRef = useRef(false);
  const locationLabel = location ? homeLocationCardLabel(location) : 'Не выбран';
  const serverLabel = isAutoMode && location ? `Авто: ${locationLabel}` : locationLabel;
  const visibleServerLabel = locationLabel;
  return (
    <VexPressable
      disabled={disabled}
      onPress={() => {
        if (!touchMovedRef.current) {
          onPress(latencyText);
        }
      }}
      onPressIn={(event: GestureResponderEvent) => {
        touchStartRef.current = {
          x: event.nativeEvent.pageX,
          y: event.nativeEvent.pageY,
        };
        touchMovedRef.current = false;
      }}
      onTouchMove={(event: GestureResponderEvent) => {
        const touchStart = touchStartRef.current;
        if (!touchStart) {
          return;
        }
        touchMovedRef.current = !isServerChipTap(touchStart, {
          x: event.nativeEvent.pageX,
          y: event.nativeEvent.pageY,
        });
      }}
      style={[styles.serverChip, polish.card, isSelected && polish.selected, disabled && styles.serverChipDisabled]}
      hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
      title="Выбрать сервер подключения"
      accessibilityRole="button"
      accessibilityLabel={`Открыть серверы: ${serverLabel}, ${availableNodeCountText(availableNodeCount)}, задержка ${latencyText}`}
    >
      <View style={styles.serverChipCountryIsland}>
        <CountryIsland countryCode={location?.countryCode} selected={isSelected} />
      </View>
      <View style={[styles.serverChipFlag, polish.flag]}>
        <Globe2 color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
      </View>
      <View style={styles.serverChipCopy}>
        <Text numberOfLines={1} style={[styles.serverChipLabel, polish.label]}>
          {visibleServerLabel}
        </Text>
        <Text style={[styles.serverChipCaption, polish.caption]}>{availableNodeCountText(availableNodeCount)} · {availableNodeCount > 0 ? 'доступно' : 'нет доступных'}</Text>
      </View>
      <View style={[styles.serverLatencyPill, polish.latency]}>
        <Gauge color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
        <Text numberOfLines={1} style={[styles.serverLatencyText, polish.latencyText]}>{latencyText}</Text>
      </View>
      {isSelected ? (
        <View style={[styles.serverSelectedIcon, polish.selection]}>
          <Check color={vexTheme.colors.text} size={18} strokeWidth={1.75} />
        </View>
      ) : <Circle color={vexTheme.colors.textMuted} size={18} strokeWidth={1.75} />}
    </VexPressable>
  );
});

const polish = StyleSheet.create({
  card: { borderRadius: 16, minHeight: 80 },
  selected: { backgroundColor: vexTheme.colors.surfaceRaised },
  flag: { height: 44, width: 44 },
  label: { fontWeight: '600', marginTop: 0 },
  caption: { fontWeight: '400', marginTop: 4 },
  latency: { borderRadius: 10, gap: 4 },
  latencyText: { color: vexTheme.colors.textSecondary, fontWeight: '500' },
  selection: { backgroundColor: vexTheme.colors.surfaceRaised, borderRadius: 10 },
});

import React, { useRef } from 'react';
import { View, Text, type GestureResponderEvent } from 'react-native';
import { Check, Circle, Gauge } from 'lucide-react-native';
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

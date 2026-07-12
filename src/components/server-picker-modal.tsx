import React, { useEffect, useState } from 'react';
import { View, Text, ScrollView } from 'react-native';
import { VexPressable } from '@/ui/vex-ui';
import { measureEndpointLatency } from '@/native/vexVpn';
import { fallbackLocationEndpoint } from '@/vpn/locationEndpoint';
import { X, RefreshCw, CheckCircle2 } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import type { ServerSelectionMode } from '@/vpn/serverSelection';
import { serverLocationLabel, locationLatencyText, locationStatusText } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';

export interface ServerPickerModalProps {
  isVpnBusy: boolean;
  locations: VpnLocation[];
  selectedLatencyText?: string;
  selectionMode: ServerSelectionMode;
  selectedLocationId: string;
  visible: boolean;
  onAutoSelect: () => void;
  onClose: () => void;
  onSelect: (locationId: string) => void;
}

export const ServerPickerModal = React.memo(function ServerPickerModal({
  isVpnBusy,
  locations,
  selectedLatencyText,
  selectionMode,
  selectedLocationId,
  visible,
  onAutoSelect,
  onClose,
  onSelect,
}: ServerPickerModalProps) {
  if (!visible) {
    return null;
  }

  return (
    <ServerPickerContent
      isVpnBusy={isVpnBusy}
      locations={locations}
      selectedLatencyText={selectedLatencyText}
      selectionMode={selectionMode}
      selectedLocationId={selectedLocationId}
      onAutoSelect={onAutoSelect}
      onClose={onClose}
      onSelect={onSelect}
    />
  );
});

type ServerPickerContentProps = Omit<ServerPickerModalProps, 'visible'>;

export const ServerPickerContent = React.memo(function ServerPickerContent({
  isVpnBusy,
  locations,
  selectedLatencyText,
  selectionMode,
  selectedLocationId,
  onAutoSelect,
  onClose,
  onSelect,
}: ServerPickerContentProps) {
  const autoSelected = selectionMode === 'auto';
  const [deviceLatencies, setDeviceLatencies] = useState<Record<string, number>>({});

  useEffect(() => {
    // TODO(VEX Android latency): VEX Dev 1.0.79 still receives the cached 7-9 ms
    // control-plane values here while `adb shell ping` reports ~45 ms to Germany
    // and ~20 ms to Finland. Resolve the public endpoint on the underlying
    // Android network (or return a server-provided numeric probe address), then
    // verify both rows against simultaneous ADB pings on the real phone.
    let cancelled = false;
    void Promise.all(locations.map(async (location) => {
      const endpoint = fallbackLocationEndpoint(location.countryCode) || location.endpoint;
      if (!endpoint) return null;
      try {
        const latency = await measureEndpointLatency(endpoint);
        return typeof latency === 'number' && Number.isFinite(latency)
          ? [location.id, Math.max(0, latency)] as const
          : null;
      } catch {
        return null;
      }
    })).then((measurements) => {
      if (cancelled) return;
      const next: Record<string, number> = {};
      for (const measurement of measurements) {
        if (measurement) next[measurement[0]] = measurement[1];
      }
      setDeviceLatencies(next);
    });
    return () => {
      cancelled = true;
    };
  }, [locations]);

  return (
    <View style={styles.serverModal}>
      <View style={styles.serverModalHeader}>
        <View>
          <Text style={styles.serverModalEyebrow}>VEX VPN</Text>
          <Text style={styles.serverModalTitle}>Серверы</Text>
          <Text style={styles.serverModalSubtitle}>Ближайший стабильный узел для текущей сессии.</Text>
        </View>
        <VexPressable onPress={onClose} style={styles.serverModalClose} hoverStyle={{ opacity: 0.72 }} title="Закрыть выбор сервера" accessibilityLabel="Закрыть выбор сервера">
          <X color="#A7B9BD" size={24} strokeWidth={2.5} />
        </VexPressable>
      </View>

      <ScrollView contentContainerStyle={styles.serverModalList} showsVerticalScrollIndicator={false}>
        <AutoServerRow
          disabled={isVpnBusy}
          onPress={onAutoSelect}
          selected={autoSelected}
        />
        {locations.map((location) => {
          const selected = selectionMode === 'manual' && location.id === selectedLocationId;
          const measuredLatency = deviceLatencies[location.id];
          return (
            <ServerLocationRow
              disabled={isVpnBusy}
              key={location.id}
              latencyTextOverride={Number.isFinite(measuredLatency)
                ? `${Math.round(measuredLatency)} мс`
                : selected
                  ? selectedLatencyText
                  : undefined}
              location={location}
              onSelect={onSelect}
              selected={selected}
            />
          );
        })}
      </ScrollView>
    </View>
  );
});


type AutoServerRowProps = {
  disabled: boolean;
  onPress: () => void;
  selected: boolean;
};

const AutoServerRow = React.memo(function AutoServerRow({ disabled, onPress, selected }: AutoServerRowProps) {
  return (
    <VexPressable
      disabled={disabled}
      onPress={onPress}
      style={[styles.serverRow, selected && styles.serverRowSelected, disabled && !selected && styles.serverRowDisabled]}
      hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.98)', borderColor: 'rgba(34,211,238,0.42)' }}
      title="Автоматический выбор оптимального сервера"
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      accessibilityLabel="Автоматически выбирать лучший сервер"
    >
      <View style={styles.serverRowMain}>
        <View style={styles.serverRowFlagBox}>
          <RefreshCw color="#22D3EE" size={18} strokeWidth={2.7} />
        </View>
        <View style={styles.serverRowCopy}>
          <Text numberOfLines={1} style={[styles.serverRowName, selected && styles.serverRowNameSelected]}>Автоматически</Text>
          <View style={styles.serverRowStatusLine}>
            <View style={[styles.serverHealthDot, styles.serverHealthDotActive]} />
            <Text numberOfLines={1} style={styles.serverRowStatus}>Лучший доступный сервер</Text>
          </View>
        </View>
      </View>
      <View style={styles.serverRowSide}>
        <Text style={[styles.serverRowLatency, selected && styles.serverRowLatencySelected]}>Авто</Text>
        {selected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
      </View>
    </VexPressable>
  );
});

type ServerLocationRowProps = {
  disabled: boolean;
  latencyTextOverride?: string;
  location: VpnLocation;
  onSelect: (locationId: string) => void;
  selected: boolean;
};

const ServerLocationRow = React.memo(function ServerLocationRow({
  disabled,
  latencyTextOverride,
  location,
  onSelect,
  selected,
}: ServerLocationRowProps) {
  const latencyText = latencyTextOverride || locationLatencyText(location);
  const handlePress = React.useCallback(() => onSelect(location.id), [location.id, onSelect]);
  return (
    <VexPressable
      disabled={disabled}
      onPress={handlePress}
      style={[styles.serverRow, selected && styles.serverRowSelected, disabled && !selected && styles.serverRowDisabled]}
      hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.98)', borderColor: 'rgba(34,211,238,0.42)' }}
      title={`Подключиться к серверу ${location.city}`}
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      accessibilityLabel={`Подключаться к серверу ${serverLocationLabel(location)}, задержка ${latencyText}`}
    >
      <View style={styles.serverRowMain}>
        <View style={styles.serverRowFlagBox}>
          <Text style={styles.serverRowFlag}>{location.flagEmoji || location.countryCode}</Text>
        </View>
        <View style={styles.serverRowCopy}>
          <Text numberOfLines={1} style={[styles.serverRowName, selected && styles.serverRowNameSelected]}>{location.city}</Text>
          <View style={styles.serverRowStatusLine}>
            <View style={[styles.serverHealthDot, location.healthyNodes > 0 && styles.serverHealthDotActive]} />
            <Text numberOfLines={1} style={styles.serverRowStatus}>{locationStatusText(location)}</Text>
          </View>
        </View>
      </View>
      <View style={styles.serverRowSide}>
        <Text style={[styles.serverRowLatency, selected && styles.serverRowLatencySelected]}>
          {latencyText}
        </Text>
        {selected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
      </View>
    </VexPressable>
  );
});

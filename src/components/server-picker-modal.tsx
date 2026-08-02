import React from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { VexPressable } from '@/ui/vex-ui';
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
    <Modal
      animationType="slide"
      onRequestClose={onClose}
      statusBarTranslucent
      transparent
      visible
    >
      <View style={drawerStyles.overlay}>
        <Pressable accessibilityLabel="Закрыть выбор сервера" onPress={onClose} style={drawerStyles.backdrop} />
        <View style={drawerStyles.sheet}>
          <View style={drawerStyles.handle} />
          <ServerPickerContent
            isVpnBusy={isVpnBusy}
            locations={locations}
            selectedLatencyText={selectedLatencyText}
            selectionMode={selectionMode}
            selectedLocationId={selectedLocationId}
            onAutoSelect={onAutoSelect}
            onClose={onClose}
            onSelect={onSelect}
            presentation="drawer"
          />
        </View>
      </View>
    </Modal>
  );
});

type ServerPickerContentProps = Omit<ServerPickerModalProps, 'visible'> & {
  presentation?: 'drawer' | 'screen';
};

export const ServerPickerContent = React.memo(function ServerPickerContent({
  isVpnBusy,
  locations,
  selectedLatencyText,
  selectionMode,
  selectedLocationId,
  onAutoSelect,
  onClose,
  onSelect,
  presentation = 'screen',
}: ServerPickerContentProps) {
  const autoSelected = selectionMode === 'auto';

  return (
    <View style={[styles.serverModal, presentation === 'drawer' && styles.serverDrawer]}>
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
          return (
            <ServerLocationRow
              disabled={isVpnBusy}
              key={location.id}
              latencyTextOverride={selected ? selectedLatencyText : undefined}
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

const drawerStyles = StyleSheet.create({
  overlay: {
    backgroundColor: 'rgba(0, 7, 9, 0.58)',
    flex: 1,
    justifyContent: 'flex-end',
  },
  backdrop: {
    flex: 1,
  },
  sheet: {
    backgroundColor: '#031013',
    borderColor: 'rgba(159, 218, 223, 0.18)',
    borderTopLeftRadius: 30,
    borderTopRightRadius: 30,
    borderWidth: 1,
    maxHeight: '76%',
    minHeight: 340,
    overflow: 'hidden',
  },
  handle: {
    alignSelf: 'center',
    backgroundColor: 'rgba(184, 200, 203, 0.38)',
    borderRadius: 999,
    height: 4,
    marginTop: 10,
    width: 42,
  },
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

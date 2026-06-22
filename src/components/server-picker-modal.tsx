import React from 'react';
import { Modal, View, Text, Pressable, ScrollView } from 'react-native';
import { X, RefreshCw, CheckCircle2 } from 'lucide-react-native';
import type { VpnLocation } from '@/api/vexApi';
import type { ServerSelectionMode } from '@/vpn/serverSelection';
import { serverLocationLabel, locationLatencyText, locationStatusText } from '../screens/home-screen-helpers';
import { styles } from '../screens/home-screen.styles';

export interface ServerPickerModalProps {
  currentLatencyText: string;
  isVpnBusy: boolean;
  locations: VpnLocation[];
  selectionMode: ServerSelectionMode;
  selectedLocationId: string;
  visible: boolean;
  onAutoSelect: () => void;
  onClose: () => void;
  onSelect: (locationId: string) => void;
}

export function ServerPickerModal({
  currentLatencyText,
  isVpnBusy,
  locations,
  selectionMode,
  selectedLocationId,
  visible,
  onAutoSelect,
  onClose,
  onSelect,
}: ServerPickerModalProps) {
  const autoSelected = selectionMode === 'auto';
  return (
    <Modal animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen" visible={visible}>
      <View style={styles.serverModal}>
        <View style={styles.serverModalHeader}>
          <View>
            <Text style={styles.serverModalEyebrow}>VEX VPN</Text>
            <Text style={styles.serverModalTitle}>Серверы</Text>
            <Text style={styles.serverModalSubtitle}>Ближайший стабильный узел для текущей сессии.</Text>
          </View>
          <Pressable onPress={onClose} style={styles.serverModalClose} accessibilityLabel="Закрыть выбор сервера">
            <X color="#A7B9BD" size={24} strokeWidth={2.5} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.serverModalList} showsVerticalScrollIndicator={false}>
          <Pressable
            disabled={isVpnBusy}
            onPress={onAutoSelect}
            style={[styles.serverRow, autoSelected && styles.serverRowSelected, isVpnBusy && !autoSelected && styles.serverRowDisabled]}
            accessibilityRole="button"
            accessibilityState={{ selected: autoSelected, disabled: isVpnBusy }}
            accessibilityLabel="Автоматически выбирать лучший сервер"
          >
            <View style={styles.serverRowMain}>
              <View style={styles.serverRowFlagBox}>
                <RefreshCw color="#22D3EE" size={18} strokeWidth={2.7} />
              </View>
              <View style={styles.serverRowCopy}>
                <Text numberOfLines={1} style={[styles.serverRowName, autoSelected && styles.serverRowNameSelected]}>Автоматически</Text>
                <View style={styles.serverRowStatusLine}>
                  <View style={[styles.serverHealthDot, styles.serverHealthDotActive]} />
                  <Text numberOfLines={1} style={styles.serverRowStatus}>Лучший доступный сервер</Text>
                </View>
              </View>
            </View>
            <View style={styles.serverRowSide}>
              <Text style={[styles.serverRowLatency, autoSelected && styles.serverRowLatencySelected]}>Авто</Text>
              {autoSelected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
            </View>
          </Pressable>
          {locations.map((location) => {
            const selected = selectionMode === 'manual' && location.id === selectedLocationId;
            const disabled = isVpnBusy;
            return (
              <Pressable
                key={location.id}
                disabled={disabled}
                onPress={() => onSelect(location.id)}
                style={[styles.serverRow, selected && styles.serverRowSelected, disabled && !selected && styles.serverRowDisabled]}
                accessibilityRole="button"
                accessibilityState={{ selected, disabled }}
                accessibilityLabel={`Подключаться к серверу ${serverLocationLabel(location)}, задержка ${selected ? currentLatencyText : locationLatencyText(location)}`}
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
                    {selected ? currentLatencyText : locationLatencyText(location)}
                  </Text>
                  {selected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
                </View>
              </Pressable>
            );
          })}
        </ScrollView>
      </View>
    </Modal>
  );
}

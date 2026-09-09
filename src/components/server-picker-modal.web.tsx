import React from 'react';
import { Modal, StyleSheet, Text, View } from 'react-native';

import type { VpnLocation } from '@/api/vexApi';
import { VexPressable } from '@/ui/vex-ui';
import type { ServerSelectionMode } from '@/vpn/serverSelection';
import {
  locationStatusText,
} from '../screens/home-screen-helpers';
import {
  groupVpnLocationsByCountry,
  serverCountLabel,
  serverPickerLocationTitle,
  serverPickerRowPresentation,
} from '../screens/server-picker-interactions';

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

type ServerPickerContentProps = Omit<ServerPickerModalProps, 'visible' | 'onClose'>;

export const ServerPickerModal = React.memo(function ServerPickerModal({
  visible,
  onClose,
  ...props
}: ServerPickerModalProps) {
  if (!visible) return null;

  return (
    <Modal animationType="fade" onRequestClose={onClose} transparent visible={visible}>
      <View style={styles.backdrop}>
        <VexPressable
          accessibilityLabel="Закрыть выбор локации"
          accessibilityRole="button"
          onPress={onClose}
          style={styles.dismissArea}
        />
        <View style={styles.sheet} testID="server-picker-sheet">
          <View style={styles.handle} />
          <ServerPickerContent {...props} />
        </View>
      </View>
    </Modal>
  );
});

export const ServerPickerContent = React.memo(function ServerPickerContent({
  isVpnBusy,
  locations,
  selectedLatencyText,
  selectedLocationId,
  selectionMode,
  onAutoSelect,
  onSelect,
}: ServerPickerContentProps) {
  const countryGroups = React.useMemo(() => groupVpnLocationsByCountry(locations), [locations]);
  const [expandedCountryCode, setExpandedCountryCode] = React.useState<string | null>(null);

  return (
    <View style={styles.content}>
      <Text style={styles.eyebrow}>ЛОКАЦИЯ</Text>
      <Text style={styles.title}>Выберите сервер</Text>
      <Text style={styles.subtitle}>VEX выберет лучший сервер автоматически. Страну и конкретный сервер можно указать вручную.</Text>
      <ServerPickerRow
        disabled={isVpnBusy}
        leading="↻"
        onPress={onAutoSelect}
        selected={selectionMode === 'auto'}
        supportingText="Лучший сервер среди всех стран"
        testID="server-picker-auto"
        title="Автоматически"
      />
      {countryGroups.map((group) => {
        const countrySelected = selectionMode === 'manual'
          && group.locations.some((location) => location.id === selectedLocationId);
        const expanded = expandedCountryCode === group.countryCode;
        const bestLocation = group.bestLocation;
        const bestPresentation = bestLocation ? serverPickerRowPresentation(bestLocation, {
          busy: isVpnBusy,
          selected: bestLocation.id === selectedLocationId,
          selectedLatencyText,
        }) : null;
        const serverCount = group.locations.length;
        const bestLocationOrdinal = bestLocation
          ? group.locations.findIndex((location) => location.id === bestLocation.id) + 1
          : undefined;
        return (
          <View key={group.countryCode} style={[styles.countryCard, countrySelected && styles.countryCardSelected]}>
            <ServerPickerRow
              disabled={!bestLocation || Boolean(bestPresentation?.disabled)}
              leading={group.flagEmoji || group.countryCode}
              onPress={() => {
                if (serverCount === 1 && bestLocation) {
                  onSelect(bestLocation.id);
                  return;
                }
                setExpandedCountryCode(expanded ? null : group.countryCode);
              }}
              selected={serverCount === 1 && countrySelected}
              supportingText={bestLocation
                ? `${serverCountLabel(serverCount)} · лучший ${serverPickerLocationTitle(bestLocation, bestLocationOrdinal)} · ${bestPresentation?.latency}`
                : 'Нет доступных серверов'}
              testID={`server-picker-country-${group.countryCode.toLowerCase()}`}
              title={group.title}
              trailing={serverCount > 1 ? `${countrySelected ? '✓  ' : ''}${expanded ? '⌃' : '⌄'}` : undefined}
            />
            {expanded ? group.locations.map((location, index) => {
              const selected = selectionMode === 'manual' && location.id === selectedLocationId;
              const presentation = serverPickerRowPresentation(location, {
                busy: isVpnBusy,
                selected,
                selectedLatencyText,
              });
              return (
                <ServerPickerRow
                  accessibilityLabel={presentation.accessibilityLabel}
                  disabled={presentation.disabled}
                  key={location.id}
                  leading={location.id === bestLocation?.id ? '★' : '•'}
                  onPress={() => onSelect(location.id)}
                  selected={presentation.selected}
                  supportingText={`${locationStatusText(location)} · ${presentation.latency}${location.id === bestLocation?.id ? ' · лучший' : ''}`}
                  testID={`server-picker-${location.id}`}
                  title={serverPickerLocationTitle(location, index + 1)}
                />
              );
            }) : null}
          </View>
        );
      })}
      {locations.length === 0 ? (
        <Text accessibilityRole="alert" style={styles.empty}>Серверы временно недоступны. Попробуйте снова позже.</Text>
      ) : null}
    </View>
  );
});

function ServerPickerRow({
  accessibilityLabel,
  disabled,
  leading,
  onPress,
  selected,
  supportingText,
  testID,
  title,
  trailing,
}: {
  accessibilityLabel?: string;
  disabled: boolean;
  leading: string;
  onPress: () => void;
  selected: boolean;
  supportingText: string;
  testID: string;
  title: string;
  trailing?: string;
}) {
  return (
    <VexPressable
      accessibilityLabel={accessibilityLabel ?? `${title}. ${supportingText}`}
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={[styles.row, selected && styles.rowSelected, disabled && styles.rowDisabled]}
      testID={testID}
    >
      <Text style={styles.leading}>{leading}</Text>
      <View style={styles.rowCopy}>
        <Text style={styles.rowTitle}>{title}</Text>
        <Text style={styles.rowMeta}>{supportingText}</Text>
      </View>
      <Text style={styles.trailing}>{selected ? '✓' : trailing ?? ''}</Text>
    </VexPressable>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    backgroundColor: 'rgba(0, 8, 11, 0.68)',
    flex: 1,
    justifyContent: 'flex-end',
  },
  dismissArea: {
    flex: 1,
  },
  sheet: {
    alignSelf: 'center',
    backgroundColor: '#041315',
    borderColor: 'rgba(121,239,247,0.18)',
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    borderWidth: 1,
    maxHeight: '78%',
    maxWidth: 430,
    overflow: 'hidden',
    width: '100%',
  },
  handle: {
    alignSelf: 'center',
    backgroundColor: 'rgba(205,229,233,0.32)',
    borderRadius: 999,
    height: 4,
    marginTop: 10,
    width: 42,
  },
  content: {
    paddingBottom: 22,
    paddingHorizontal: 20,
    paddingTop: 14,
  },
  countryCard: {
    borderColor: 'rgba(103,232,249,0.12)',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 8,
    overflow: 'hidden',
  },
  countryCardSelected: {
    borderColor: 'rgba(103,232,249,0.34)',
  },
  eyebrow: {
    color: '#67E8F9',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.2,
  },
  empty: {
    color: '#A7B9BD',
    fontSize: 14,
    lineHeight: 20,
    paddingHorizontal: 8,
    paddingVertical: 20,
  },
  title: {
    color: '#F4FCFD',
    fontSize: 26,
    fontWeight: '800',
    marginTop: 5,
  },
  subtitle: {
    color: '#A7B9BD',
    fontSize: 14,
    lineHeight: 20,
    marginBottom: 14,
    marginTop: 3,
  },
  row: {
    alignItems: 'center',
    borderBottomColor: 'rgba(159, 218, 223, 0.12)',
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    minHeight: 68,
    paddingHorizontal: 8,
  },
  rowSelected: {
    backgroundColor: 'rgba(67,217,231,0.1)',
    borderRadius: 16,
  },
  rowDisabled: {
    opacity: 0.5,
  },
  leading: {
    color: '#67E8F9',
    fontSize: 25,
    textAlign: 'center',
    width: 42,
  },
  rowCopy: {
    flex: 1,
    paddingHorizontal: 8,
  },
  rowTitle: {
    color: '#F4FCFD',
    fontSize: 16,
    fontWeight: '700',
  },
  rowMeta: {
    color: '#A7B9BD',
    fontSize: 13,
    marginTop: 3,
  },
  trailing: {
    color: '#67E8F9',
    fontSize: 21,
    fontWeight: '800',
    width: 28,
  },
});

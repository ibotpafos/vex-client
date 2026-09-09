import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import React, { useState } from 'react';
import { Platform, Text, View } from 'react-native';

import type { VpnLocation } from '@/api/vexApi';
import { LocationHomeHero } from '@/components/location-home-hero';
import { MobileUpdateNoticeBanner, UpdateCenterButton } from '@/components/update-center';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexPressable } from '@/ui/vex-ui';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

import { ServerPickerModal } from '../components/server-picker-modal';
import { serverPickerActionForSource } from './server-picker-interactions';
import { styles } from './home-screen.styles';

export default function App() {
  useRenderProfilerMark('HomeScreen');
  const {
    session,
    vpnError,
    isVpnBusy,
    isKeyRotationBusy,
    isUpdateCenterVisible,
    serverSelectionMode,
    selectedLocationId,
    connectionPhase,
    pulseProgress,
    activeProfile,
    selectedLocation,
    selectedLatencyText,
    powerButtonDisabled,
    handlePowerPress,
    handleRotateKeyPress,
    handleLocationPress,
    handleAutoServerSelectionPress,
    availableLocations,
    isLocationsRefreshing,
    locationsRefreshError,
    refreshLocationsForPicker,
    retryLocations,
    openUpdateCenter,
    closeUpdateCenter,
  } = useVpnConnectionContext();
  const [isServerPickerVisible, setIsServerPickerVisible] = useState(false);
  const [serverPickerSnapshot, setServerPickerSnapshot] = useState<{
    latencyText: string;
    locations: VpnLocation[];
  } | null>(null);

  function openServerPicker() {
    if (serverPickerActionForSource('all_locations') !== 'open_picker') {
      return;
    }
    setServerPickerSnapshot({
      latencyText: selectedLatencyText,
      locations: availableLocations.map((location) => ({ ...location })),
    });
    void refreshLocationsForPicker().catch(() => undefined);
    requestAnimationFrame(() => setIsServerPickerVisible(true));
  }

  return (
    <View style={styles.screen}>
      <View style={styles.shell}>
      {Platform.OS !== 'android' ? <StatusBar style="light" /> : null}
      {!session ? (
        <View style={styles.centerState}>
          <VexNativeActivityIndicator color="#22D3EE" size="large" />
          <Text style={styles.centerStateText}>Загружаем VEX</Text>
        </View>
      ) : (
        <LocationHomeHero
          connectionPhase={connectionPhase}
          headerActions={(
            <UpdateCenterButton
              visible={isUpdateCenterVisible}
              onClose={closeUpdateCenter}
              onOpen={openUpdateCenter}
            />
          )}
          latencyText={selectedLatencyText}
          location={selectedLocation}
          onLocationPress={openServerPicker}
          onPowerPress={handlePowerPress}
          onSettingsPress={() => {
            playSelectionHaptic();
            router.push('/(app)/settings');
          }}
          powerButtonDisabled={powerButtonDisabled}
          pulseProgress={pulseProgress}
          selectionMode={serverSelectionMode}
        >
          <MobileUpdateNoticeBanner onOpen={openUpdateCenter} />
          {activeProfile?.rotationRequired ? (
            <VexPressable
              disabled={isKeyRotationBusy || isVpnBusy}
              onPress={handleRotateKeyPress}
              style={styles.rotationNotice}
              hoverStyle={{ opacity: 0.86 }}
              title="Обновить ключи VPN"
            >
              <Text numberOfLines={2} style={styles.vpnNoticeText}>
                {isKeyRotationBusy ? 'Обновляем VPN-ключ...' : 'Ключ VPN устарел. Нажмите, чтобы обновить.'}
              </Text>
            </VexPressable>
          ) : null}
          {availableLocations.length === 0 ? (
            <Text accessibilityRole="alert" style={styles.vpnErrorText}>
              Серверы временно недоступны. Обновите каталог и попробуйте снова.
            </Text>
          ) : null}
          {vpnError ? <Text numberOfLines={2} style={styles.vpnErrorText}>{vpnError}</Text> : null}
        </LocationHomeHero>
      )}
      <ServerPickerModal
        isVpnBusy={isVpnBusy}
        isRefreshing={isLocationsRefreshing}
        locations={serverPickerSnapshot?.locations ?? availableLocations}
        refreshError={locationsRefreshError}
        selectedLatencyText={serverPickerSnapshot?.latencyText ?? selectedLatencyText}
        selectionMode={serverSelectionMode}
        selectedLocationId={selectedLocationId}
        visible={isServerPickerVisible}
        onAutoSelect={() => {
          setIsServerPickerVisible(false);
          void handleAutoServerSelectionPress(false);
        }}
        onClose={() => setIsServerPickerVisible(false)}
        onRetry={() => {
          void retryLocations().catch(() => undefined);
        }}
        onSelect={(locationId) => {
          setIsServerPickerVisible(false);
          void handleLocationPress(locationId, false);
        }}
      />
      </View>
    </View>
  );
}

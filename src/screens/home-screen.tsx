import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import { Power, Settings } from 'lucide-react-native';
import React, { useCallback, useMemo, useRef, useState } from 'react';
import { Animated, FlatList, Platform, ScrollView, Text, useWindowDimensions, View, type ListRenderItem } from 'react-native';

import type { VpnLocation } from '@/api/vexApi';
import { HomeNativeHeader } from '@/components/home-native-header';
import { MobileUpdateNoticeBanner, UpdateCenterButton } from '@/components/update-center';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { vexTheme } from '@/ui/vex-theme';
import { VexScreen, vexSharedStyles, VexPressable } from '@/ui/vex-ui';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

import { ServerChip } from '../components/server-chip';
import { ServerPickerModal } from '../components/server-picker-modal';
import { TrafficStats } from '../components/traffic-stats';
import { type ConnectionPhase, locationLatencyText, serverLocationLabel } from './home-screen-helpers';
import { countryGroups, stableCountryGroups, type CountryGroup } from './country-groups';
import { serverPickerActionForSource } from './server-picker-interactions';
import { styles } from './home-screen.styles';
import {
  locationCarouselItemLayout,
} from './home-location-previews';

export default function App() {
  useRenderProfilerMark('HomeScreen');
  const {
    session,
    vpnError,
    isVpnBusy,
    isKeyRotationBusy,
    isUpdateCenterVisible,
    isConnected,
    serverSelectionMode,
    selectedLocationId,
    connectionPhase,
    pulseProgress,
    spinProgress,
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
    countryTitle?: string;
    locations: VpnLocation[];
  } | null>(null);
  const { width: viewportWidth } = useWindowDimensions();
  const reduceMotionVisuals = Platform.OS === 'android';

  const powerButtonText = connectionPhase === 'switching'
    ? 'Переключение'
    : connectionPhase === 'blocked'
      ? 'Отключить'
    : connectionPhase === 'degraded'
      ? 'Восстанавливаем'
    : connectionPhase === 'verifying'
      ? 'Проверяем'
    : connectionPhase === 'connecting'
    ? 'Отменить'
    : connectionPhase === 'disconnecting'
      ? 'Отключение'
      : connectionPhase === 'connected'
        ? 'Подключено'
        : 'Подключить';

  const powerSubtext = connectionPhase === 'connected'
    ? 'VPN активен'
    : connectionPhase === 'blocked'
      ? 'Интернет заблокирован'
    : connectionPhase === 'degraded'
      ? 'Чиним туннель'
    : connectionPhase === 'verifying'
      ? 'Ждем handshake'
    : connectionPhase === 'switching'
      ? 'Меняем сервер'
    : connectionPhase === 'connecting'
      ? 'Запускаем'
      : connectionPhase === 'disconnecting'
        ? 'Завершаем'
        : 'VPN выключен';
  const groupsRef = useRef<CountryGroup[]>([]);
  const groups = stableCountryGroups(
    groupsRef.current,
    countryGroups(availableLocations, selectedLocationId, selectedLocation),
  );
  groupsRef.current = groups;
  const locationPreviews = groups;
  const carouselWidth = Math.min(viewportWidth - (viewportWidth <= 360 ? 16 : 24), 430);
  const carouselCardWidth = carouselWidth - 44;
  const carouselSnapInterval = carouselCardWidth + vexTheme.spacing.sm;
  const locationPreviewCount = locationPreviews.length;
  const getLocationItemLayout = useCallback(
    (_data: ArrayLike<CountryGroup> | null | undefined, index: number) => (
      locationCarouselItemLayout(carouselCardWidth, vexTheme.spacing.sm, index)
    ),
    [carouselCardWidth],
  );
  const carouselContentContainerStyle = useMemo(
    () => ({ paddingRight: carouselWidth - carouselCardWidth }),
    [carouselCardWidth, carouselWidth],
  );
  const renderLocationPreview = useCallback<ListRenderItem<CountryGroup>>(({ item: group }) => {
    const location = group.representative;
    return (
      <LocationCarouselItem
        availableNodeCount={group.availableNodeCount}
        disabled={isVpnBusy}
        isAutoMode={group.isSelected && serverSelectionMode === 'auto'}
        isSelected={group.isSelected}
        latencyText={group.isSelected ? selectedLatencyText : locationLatencyText(location)}
        location={location}
        onSelect={() => {
          if (serverPickerActionForSource('carousel') !== 'open_picker') return;
          setServerPickerSnapshot({
            latencyText: selectedLatencyText,
            countryTitle: serverLocationLabel(location),
            locations: group.locations.map((member) => ({ ...member })),
          });
          requestAnimationFrame(() => setIsServerPickerVisible(true));
        }}
        width={carouselCardWidth}
      />
    );
  }, [
    carouselCardWidth,
    isVpnBusy,
    selectedLatencyText,
    serverSelectionMode,
  ]);

  return (
    <VexScreen contentStyle={styles.shell}>
      {Platform.OS !== 'android' ? <StatusBar style="light" /> : null}
      <HomeNativeHeader
        actions={(
          <View style={styles.topActions}>
            <UpdateCenterButton
            visible={isUpdateCenterVisible}
            onClose={closeUpdateCenter}
            onOpen={openUpdateCenter}
            />
            <VexPressable
              onPress={() => {
                playSelectionHaptic();
                router.push('/(app)/settings');
              }}
              style={vexSharedStyles.iconButton}
              hoverStyle={{ opacity: 0.72 }}
              title="Настройки"
              accessibilityLabel="Настройки"
            >
              <Settings color="#EAF7F8" size={24} strokeWidth={2.4} />
            </VexPressable>
          </View>
        )}
      />
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
        style={styles.scroll}
      >
        <MobileUpdateNoticeBanner onOpen={openUpdateCenter} />

        {!session ? (
          <View style={styles.centerState}>
            <VexNativeActivityIndicator color="#22D3EE" size="large" />
            <Text style={styles.centerStateText}>Загружаем VEX</Text>
          </View>
        ) : (
          <View style={styles.mainContent}>
            <PowerHero
              connectionPhase={connectionPhase}
              isConnected={isConnected}
              isVpnBusy={isVpnBusy}
              onPowerPress={handlePowerPress}
              pulseProgress={pulseProgress}
              spinProgress={spinProgress}
              powerButtonDisabled={powerButtonDisabled}
              powerButtonText={powerButtonText}
              powerSubtext={powerSubtext}
              reduceMotionVisuals={reduceMotionVisuals}
            />

            <TrafficStats />

            <View style={styles.locationsSection}>
              <View style={styles.locationsHeader}>
                <Text style={styles.locationsTitle}>Локации</Text>
                <VexPressable
                  disabled={isVpnBusy}
                  onPress={() => {
                    if (serverPickerActionForSource('all_locations') !== 'open_picker') {
                      return;
                    }
                    setServerPickerSnapshot({
                      latencyText: selectedLatencyText,
                      locations: groups.flatMap((group) => group.locations.map((location) => ({ ...location }))),
                    });
                    void refreshLocationsForPicker().catch(() => undefined);
                    requestAnimationFrame(() => setIsServerPickerVisible(true));
                  }}
                  style={styles.locationsAllButton}
                  title="Все локации"
                  accessibilityLabel="Открыть все локации"
                >
                  <Text style={styles.locationsAllText}>Все</Text>
                </VexPressable>
              </View>
              <FlatList
                bounces={false}
                contentContainerStyle={carouselContentContainerStyle}
                data={locationPreviews}
                decelerationRate="fast"
                disableIntervalMomentum
                getItemLayout={getLocationItemLayout}
                horizontal
                initialNumToRender={locationPreviewCount}
                keyExtractor={countryGroupKeyExtractor}
                maxToRenderPerBatch={locationPreviewCount}
                nestedScrollEnabled
                overScrollMode="never"
                removeClippedSubviews={false}
                renderItem={renderLocationPreview}
                showsHorizontalScrollIndicator={false}
                snapToAlignment="start"
                snapToInterval={carouselSnapInterval}
                style={styles.locationCarousel}
              />
            </View>

            <View pointerEvents="none" style={styles.protocolSpacer} />
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
            {vpnError ? <Text numberOfLines={2} style={styles.vpnErrorText}>{vpnError}</Text> : null}
          </View>
        )}
      </ScrollView>
      <ServerPickerModal
        isVpnBusy={isVpnBusy}
        countryTitle={serverPickerSnapshot?.countryTitle}
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
    </VexScreen>
  );
}

function countryGroupKeyExtractor(group: CountryGroup): string {
  return group.id;
}

type LocationCarouselItemProps = {
  availableNodeCount: number;
  disabled: boolean;
  isAutoMode: boolean;
  isSelected: boolean;
  latencyText: string;
  location: VpnLocation;
  onSelect: (locationId: string) => void;
  width: number;
};

const LocationCarouselItem = React.memo(function LocationCarouselItem({
  availableNodeCount,
  disabled,
  isAutoMode,
  isSelected,
  latencyText,
  location,
  onSelect,
  width,
}: LocationCarouselItemProps) {
  const handlePress = useCallback(() => onSelect(location.id), [location.id, onSelect]);
  const itemStyle = useMemo(() => [styles.locationCarouselItem, { width }], [width]);
  return (
    <View style={itemStyle}>
      <ServerChip
        availableNodeCount={availableNodeCount}
        disabled={disabled}
        isAutoMode={isAutoMode}
        isSelected={isSelected}
        latencyText={latencyText}
        location={location}
        onPress={handlePress}
      />
    </View>
  );
});

type PowerHeroProps = {
  connectionPhase: ConnectionPhase;
  isConnected: boolean;
  isVpnBusy: boolean;
  onPowerPress: () => void;
  pulseProgress: Animated.Value;
  spinProgress: Animated.Value;
  powerButtonDisabled: boolean;
  powerButtonText: string;
  powerSubtext: string;
  reduceMotionVisuals: boolean;
};

const PowerHero = React.memo(function PowerHero({
  connectionPhase,
  isConnected,
  isVpnBusy,
  onPowerPress,
  pulseProgress,
  spinProgress,
  powerButtonDisabled,
  powerButtonText,
  powerSubtext,
  reduceMotionVisuals,
}: PowerHeroProps) {
  useRenderProfilerMark('PowerHero');
  const animatedScale = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, connectionPhase === 'connected' ? 1.045 : 1.02],
  });
  const glowScale = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, connectionPhase === 'idle' ? 1 : 1.12],
  });
  const glowOpacity = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [connectionPhase === 'idle' ? 0.55 : 0.72, connectionPhase === 'connected' ? 0.92 : 0.78],
  });
  const orbitOpacity = connectionPhase === 'idle' ? 0 : 1;
  const orbitRotation = spinProgress.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });
  const glowStyle = reduceMotionVisuals
    ? styles.heroGlowDesktopStatic
    : { opacity: glowOpacity, transform: [{ scale: glowScale }] };
  const outerRingStyle = reduceMotionVisuals
    ? styles.heroRingOuterDesktopStatic
    : { opacity: glowOpacity, transform: [{ scale: glowScale }] };
  const powerFrameStyle = reduceMotionVisuals
    ? undefined
    : { transform: [{ scale: animatedScale }] };
  const showOrbit = !reduceMotionVisuals && connectionPhase !== 'idle';

  return (
    <View style={styles.hero}>
      <View style={styles.powerCluster}>
        <View pointerEvents="none" style={styles.heroRingFar} />
        <View pointerEvents="none" style={styles.heroRingMid} />
        <Animated.View
          pointerEvents="none"
          style={[styles.heroGlow, glowStyle]}
        />
        <View
          pointerEvents="none"
          style={styles.heroRing}
        />
        <Animated.View
          pointerEvents="none"
          style={[styles.heroRingOuter, outerRingStyle]}
        />
        <Animated.View style={[styles.powerButtonFrame, reduceMotionVisuals && styles.powerButtonFrameDesktop, isConnected && styles.powerButtonFrameActive, isVpnBusy && styles.powerButtonBusy, powerFrameStyle]}>
          <VexPressable
            disabled={powerButtonDisabled}
            onPress={onPowerPress}
            style={styles.powerButton}
            hoverStyle={{ opacity: 0.9 }}
            title={connectionPhase === 'connecting' ? 'Отменить подключение VPN' : isConnected ? 'Отключить VPN' : 'Подключить VPN'}
            accessibilityRole="button"
            accessibilityLabel={connectionPhase === 'connecting' ? 'Отменить подключение VPN' : isConnected ? 'Отключить VPN' : 'Подключить VPN'}
          >
            {showOrbit ? (
              <Animated.View
                pointerEvents="none"
                style={[styles.powerOrbit, { opacity: orbitOpacity, transform: [{ rotate: orbitRotation }] }]}
              />
            ) : null}
            <Power color="#B9FBFF" size={58} strokeWidth={1.75} />
          </VexPressable>
        </Animated.View>
      </View>
      <Text numberOfLines={1} adjustsFontSizeToFit style={styles.powerText}>{powerButtonText}</Text>
      <Text style={styles.powerSubtext}>{powerSubtext}</Text>
    </View>
  );
});

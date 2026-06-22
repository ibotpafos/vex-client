import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import { Settings, User, ChevronRight } from 'lucide-react-native';
import React from 'react';
import { ActivityIndicator, Animated, Platform, Pressable, View, Text } from 'react-native';

import { hasPaidEntitlement } from '@/api/vexApi';
import { HomeNativeHeader } from '@/components/home-native-header';
import { UpdateCenterButton } from '@/components/update-center';
import { playSelectionHaptic } from '@/native/haptics';
import { VexScreen, vexSharedStyles } from '@/ui/vex-ui';

import { useVpnConnection } from '../vpn/useVpnConnection';
import { ServerChip } from '../components/server-chip';
import { TrafficStats } from '../components/traffic-stats';
import { ServerPickerModal } from '../components/server-picker-modal';
import { SubscriptionModal } from '../components/subscription-modal';
import { styles } from './home-screen.styles';

const vexLogo = require('../../assets/vex-logo-header.png');

export default function App() {
  const {
    session,
    vpnStatus,
    vpnError,
    isVpnBusy,
    isKeyRotationBusy,
    selectedLocationId,
    isServerPickerVisible,
    isUpdateCenterVisible,
    isSubscriptionModalVisible,
    isConnected,
    antiLeakEnabled,
    serverSelectionMode,
    connectionPhase,
    pulseProgress,
    spinProgress,
    activeProfile,
    accountTierLabel,
    accountSummaryText,
    selectedLocation,
    selectedLatencyText,
    powerButtonDisabled,
    handlePowerPress,
    openSubscriptionModal,
    closeSubscriptionModal,
    handleRotateKeyPress,
    handleLocationPress,
    handleAutoServerSelectionPress,
    openServerPicker,
    closeServerPicker,
    openUpdateCenter,
    closeUpdateCenter,
    handleOpenVpnSettingsPress,
    availableLocations,
  } = useVpnConnection();

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

  return (
    <VexScreen contentStyle={styles.shell}>
      <StatusBar style="light" />
      <HomeNativeHeader
        logoSource={vexLogo}
        planLabel={accountTierLabel}
        showPlan={Boolean(session && accountTierLabel)}
        actions={(
          <View style={styles.topActions}>
            <UpdateCenterButton
              visible={isUpdateCenterVisible}
              onClose={closeUpdateCenter}
              onOpen={openUpdateCenter}
            />
            <Pressable
              onPress={() => {
                playSelectionHaptic();
                router.push('/settings');
              }}
              style={vexSharedStyles.iconButton}
              accessibilityLabel="Настройки"
            >
              <Settings color="#A7B9BD" size={25} strokeWidth={2.4} />
            </Pressable>
          </View>
        )}
      />

      {!session ? (
        <View style={styles.centerState}>
          <ActivityIndicator color="#22D3EE" size="large" />
          <Text style={styles.centerStateText}>Загружаем VEX</Text>
        </View>
      ) : (
        <View style={styles.mainContent}>
          <Pressable onPress={openSubscriptionModal} style={styles.accountCard}>
            <View style={styles.accountHeader}>
              <View style={styles.userBadge}>
                <User color="#22D3EE" size={25} strokeWidth={2.5} />
              </View>
              <View style={styles.accountCopy}>
                <Text numberOfLines={1} style={styles.accountEmail}>{session.user.email}</Text>
                <View style={styles.accountStatusRow}>
                  <View style={[styles.accountStatusDot, hasPaidEntitlement(activeProfile?.entitlement ?? null) && styles.accountStatusDotActive]} />
                  <Text numberOfLines={1} style={styles.accountMeta}>{accountSummaryText}</Text>
                </View>
              </View>
              <View style={styles.accountActionWrap}>
                <Text style={styles.accountAction}>Управлять</Text>
                <ChevronRight color="#22D3EE" size={18} strokeWidth={2.6} />
              </View>
            </View>
          </Pressable>

          <View style={styles.hero}>
            <View pointerEvents="none" style={styles.heroBackdrop}>
              <View style={[styles.heroNode, styles.heroNodeTopLeft]} />
              <View style={[styles.heroNode, styles.heroNodeTopRight]} />
              <View style={[styles.heroLink, styles.heroLinkOne]} />
            </View>
            <Animated.View
              pointerEvents="none"
              style={[styles.heroGlow, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]}
            />
            <View
              pointerEvents="none"
              style={styles.heroRing}
            />
            <Animated.View
              pointerEvents="none"
              style={[styles.heroRingOuter, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]}
            />
            <Animated.View style={[styles.powerButtonFrame, isConnected && styles.powerButtonFrameActive, isVpnBusy && styles.powerButtonBusy, { transform: [{ scale: animatedScale }] }]}>
              <Pressable
                disabled={powerButtonDisabled}
                onPress={handlePowerPress}
                style={styles.powerButton}
                accessibilityRole="button"
                accessibilityLabel={connectionPhase === 'connecting' ? 'Отменить подключение VPN' : isConnected ? 'Отключить VPN' : 'Подключить VPN'}
              >
                <Animated.View
                  pointerEvents="none"
                  style={[styles.powerOrbit, { opacity: orbitOpacity, transform: [{ rotate: orbitRotation }] }]}
                />
                <Text numberOfLines={1} adjustsFontSizeToFit style={styles.powerText}>{powerButtonText}</Text>
                <Text style={styles.powerSubtext}>{powerSubtext}</Text>
              </Pressable>
            </Animated.View>
          </View>

          <ServerChip
            disabled={isVpnBusy}
            isAutoMode={serverSelectionMode === 'auto'}
            latencyText={selectedLatencyText}
            location={selectedLocation}
            onPress={openServerPicker}
          />
          <TrafficStats rxBytes={vpnStatus.rxBytes} txBytes={vpnStatus.txBytes} />

          <View pointerEvents="none" style={styles.protocolSpacer} />
          {activeProfile?.rotationRequired ? (
            <Pressable disabled={isKeyRotationBusy || isVpnBusy} onPress={handleRotateKeyPress} style={styles.rotationNotice}>
              <Text numberOfLines={2} style={styles.vpnNoticeText}>
                {isKeyRotationBusy ? 'Обновляем VPN-ключ...' : 'Ключ VPN устарел. Нажмите, чтобы обновить.'}
              </Text>
            </Pressable>
          ) : null}
          {Platform.OS === 'android' && antiLeakEnabled ? (
            <Pressable disabled={isVpnBusy} onPress={handleOpenVpnSettingsPress} style={styles.rotationNotice}>
              <Text numberOfLines={2} style={styles.vpnNoticeText}>
                Для максимальной защиты включите Always-on VPN и блокировку без VPN в настройках Android.
              </Text>
            </Pressable>
          ) : null}
          {vpnError ? <Text numberOfLines={2} style={styles.vpnErrorText}>{vpnError}</Text> : null}

          <ServerPickerModal
            currentLatencyText={selectedLatencyText}
            isVpnBusy={isVpnBusy}
            locations={availableLocations}
            selectionMode={serverSelectionMode}
            selectedLocationId={selectedLocationId}
            visible={isServerPickerVisible}
            onAutoSelect={handleAutoServerSelectionPress}
            onClose={closeServerPicker}
            onSelect={handleLocationPress}
          />
          <SubscriptionModal
            visible={isSubscriptionModalVisible}
            onClose={closeSubscriptionModal}
          />

        </View>
      )}
    </VexScreen>
  );
}

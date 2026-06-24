import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import { Settings } from 'lucide-react-native';
import React from 'react';
import { Animated, Platform, Pressable, View, Text } from 'react-native';

import { HomeNativeHeader } from '@/components/home-native-header';
import { MobileUpdateNoticeBanner, UpdateCenterButton } from '@/components/update-center';
import { useRenderProfilerMark } from '@/debug/render-profiler';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexSharedStyles, VexPressable } from '@/ui/vex-ui';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

import { ServerChip } from '../components/server-chip';
import { TrafficStats } from '../components/traffic-stats';
import { isTauriRuntime, type ConnectionPhase } from './home-screen-helpers';
import { styles } from './home-screen.styles';

const vexLogo = require('../../assets/vex-logo-header.png');

export default function App() {
  useRenderProfilerMark('HomeScreen');
  const {
    session,
    vpnError,
    isVpnBusy,
    isKeyRotationBusy,
    isUpdateCenterVisible,
    isConnected,
    antiLeakEnabled,
    serverSelectionMode,
    connectionPhase,
    pulseProgress,
    spinProgress,
    activeProfile,
    accountTierLabel,
    selectedLocation,
    selectedLatencyText,
    powerButtonDisabled,
    handlePowerPress,
    handleRotateKeyPress,
    openServerPicker,
    openUpdateCenter,
    closeUpdateCenter,
    handleOpenVpnSettingsPress,
  } = useVpnConnectionContext();
  const reduceMotionVisuals = isTauriRuntime() || Platform.OS === 'android';

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

  return (
    <VexScreen contentStyle={styles.shell} backgroundMapEnabled={Platform.OS !== 'android'}>
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

          <ServerChip
            disabled={isVpnBusy}
            isAutoMode={serverSelectionMode === 'auto'}
            latencyText={selectedLatencyText}
            location={selectedLocation}
            onPress={openServerPicker}
          />
          <TrafficStats />

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
          {Platform.OS === 'android' && antiLeakEnabled ? (
            <Pressable disabled={isVpnBusy} onPress={handleOpenVpnSettingsPress} style={styles.rotationNotice}>
              <Text numberOfLines={2} style={styles.vpnNoticeText}>
                Для максимальной защиты включите Always-on VPN и блокировку без VPN в настройках Android.
              </Text>
            </Pressable>
          ) : null}
          {vpnError ? <Text numberOfLines={2} style={styles.vpnErrorText}>{vpnError}</Text> : null}

        </View>
      )}
    </VexScreen>
  );
}

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
      <View pointerEvents="none" style={styles.heroBackdrop}>
        <View style={[styles.heroNode, styles.heroNodeTopLeft]} />
        <View style={[styles.heroNode, styles.heroNodeTopRight]} />
        <View style={[styles.heroLink, styles.heroLinkOne]} />
      </View>
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
          <Text numberOfLines={1} adjustsFontSizeToFit style={styles.powerText}>{powerButtonText}</Text>
          <Text style={styles.powerSubtext}>{powerSubtext}</Text>
        </VexPressable>
      </Animated.View>
    </View>
  );
});

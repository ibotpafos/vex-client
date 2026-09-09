import { ChevronRight, Power, Settings, Shield } from 'lucide-react-native';
import type { ReactNode } from 'react';
import React from 'react';
import {
  Animated,
  ImageBackground,
  type ImageSourcePropType,
  Platform,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { VpnLocation } from '@/api/vexApi';
import { VexWordmark } from '@/components/vex-wordmark';
import { VexPressable } from '@/ui/vex-ui';
import type { ConnectionPhase } from '@/screens/home-screen-helpers';
import {
  homeConnectionPresentation,
  homeLocationBackdropKey,
  homeLocationCopy,
  type HomeLocationBackdropKey,
} from '@/screens/home-screen-visual';

const locationBackgrounds: Partial<Record<HomeLocationBackdropKey, ImageSourcePropType>> = {
  de: require('../../assets/locations/frankfurt-de.png') as ImageSourcePropType,
  fi: require('../../assets/locations/helsinki-fi.png') as ImageSourcePropType,
  nl: require('../../assets/locations/amsterdam-nl.png') as ImageSourcePropType,
};

type LocationHomeHeroProps = {
  children?: ReactNode;
  connectionPhase: ConnectionPhase;
  headerActions?: ReactNode;
  location?: VpnLocation;
  latencyText: string;
  onLocationPress: () => void;
  onPowerPress: () => void;
  onSettingsPress: () => void;
  powerButtonDisabled: boolean;
  pulseProgress: Animated.Value;
};

export function LocationHomeHero({
  children,
  connectionPhase,
  headerActions,
  location,
  latencyText,
  onLocationPress,
  onPowerPress,
  onSettingsPress,
  powerButtonDisabled,
  pulseProgress,
}: LocationHomeHeroProps) {
  const safeAreaInsets = useSafeAreaInsets();
  const presentation = homeConnectionPresentation(connectionPhase);
  const locationCopy = location ? homeLocationCopy(location, latencyText) : null;
  const backgroundSource = locationBackgrounds[homeLocationBackdropKey(location)];
  const reduceMotion = Platform.OS === 'android';
  const portalScale = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, presentation.tone === 'connected' ? 1.035 : 1.018],
  });
  const portalOpacity = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [0.86, 1],
  });

  const content = (
    <View
      style={[
        styles.root,
        {
          paddingBottom: Math.max(safeAreaInsets.bottom, 22),
          paddingTop: safeAreaInsets.top,
        },
      ]}
    >
      <View pointerEvents="none" style={styles.photoShade} />
      <View style={styles.header}>
        <View accessibilityLabel="VEX VPN" pointerEvents="none" style={styles.brand}>
          <VexWordmark accessibilityHidden />
        </View>
        <View style={styles.headerActions}>
          {headerActions}
          <VexPressable
            accessibilityLabel="Настройки"
            accessibilityRole="button"
            hitSlop={12}
            hoverStyle={styles.headerButtonPressed}
            onPress={onSettingsPress}
            style={styles.headerButton}
            title="Настройки"
          >
            <Settings color="#EAF7F8" size={25} strokeWidth={2.15} />
          </VexPressable>
        </View>
      </View>

      <View accessibilityLiveRegion="polite" style={styles.statusRow}>
        <View
          style={[
            styles.statusDot,
            presentation.tone === 'connected' && styles.statusDotConnected,
            presentation.tone === 'busy' && styles.statusDotBusy,
            presentation.tone === 'warning' && styles.statusDotWarning,
          ]}
        />
        <Text style={styles.statusText}>{presentation.status}</Text>
      </View>

      <View style={styles.portalStage}>
        <Animated.View
          style={[
            styles.portalFrame,
            presentation.tone === 'connected' && styles.portalFrameConnected,
            presentation.tone === 'warning' && styles.portalFrameWarning,
            !reduceMotion && { opacity: portalOpacity, transform: [{ scale: portalScale }] },
          ]}
        >
          <VexPressable
            accessibilityLabel={presentation.action}
            accessibilityRole="button"
            disabled={powerButtonDisabled}
            hoverStyle={styles.portalPressed}
            onPress={onPowerPress}
            style={[styles.portalButton, powerButtonDisabled && styles.portalDisabled]}
            title={presentation.action}
          >
            <View pointerEvents="none" style={styles.shieldIcon}>
              <Shield color="#ECFCFD" size={58} strokeWidth={1.75} />
              <Power color="#ECFCFD" size={28} strokeWidth={2.1} style={styles.powerIcon} />
            </View>
            <Text numberOfLines={1} adjustsFontSizeToFit style={styles.portalAction}>{presentation.action}</Text>
            <Text numberOfLines={2} style={styles.portalHelper}>{presentation.helper}</Text>
          </VexPressable>
        </Animated.View>
      </View>

      <View style={styles.footer}>
        {children ? <View style={styles.notices}>{children}</View> : null}
        <VexPressable
          accessibilityLabel={locationCopy ? `Выбрать локацию. Сейчас ${locationCopy.city}` : 'Выбрать локацию'}
          accessibilityRole="button"
          disabled={powerButtonDisabled && !location}
          hoverStyle={styles.locationPressed}
          onPress={onLocationPress}
          style={styles.locationButton}
          title="Выбрать локацию"
        >
          <View style={styles.flagDisc}>
            <Text style={styles.flag}>{location?.flagEmoji ?? '🌐'}</Text>
          </View>
          <View style={styles.locationCopy}>
            <View style={styles.locationTitleRow}>
              <Text numberOfLines={1} style={styles.locationTitle}>{locationCopy?.city ?? 'Локация не выбрана'}</Text>
              <ChevronRight color="#F2F8F8" size={27} strokeWidth={2.1} />
            </View>
            <Text numberOfLines={1} style={styles.locationMeta}>{locationCopy?.countryAndLatency ?? 'Выберите доступный сервер'}</Text>
          </View>
        </VexPressable>
      </View>
    </View>
  );

  if (!backgroundSource) {
    return <View style={styles.fallbackBackground}>{content}</View>;
  }

  return (
    <ImageBackground resizeMode="cover" source={backgroundSource} style={styles.background}>
      {content}
    </ImageBackground>
  );
}

const styles = StyleSheet.create({
  background: {
    flex: 1,
    width: '100%',
  },
  fallbackBackground: {
    backgroundColor: '#06171D',
    flex: 1,
    width: '100%',
  },
  root: {
    flex: 1,
    minHeight: 640,
    overflow: 'hidden',
    paddingBottom: 22,
    paddingHorizontal: 24,
  },
  photoShade: {
    backgroundColor: 'rgba(0, 16, 23, 0.22)',
    bottom: 0,
    left: 0,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'flex-end',
    minHeight: 72,
    position: 'relative',
  },
  brand: {
    alignItems: 'center',
    justifyContent: 'center',
    left: 0,
    position: 'absolute',
    right: 0,
  },
  headerActions: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 6,
  },
  headerButton: {
    alignItems: 'center',
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  headerButtonPressed: {
    opacity: 0.68,
  },
  statusRow: {
    alignItems: 'center',
    alignSelf: 'center',
    flexDirection: 'row',
    gap: 10,
    marginTop: 3,
    paddingHorizontal: 12,
    paddingVertical: 7,
  },
  statusDot: {
    backgroundColor: '#AFC0C4',
    borderRadius: 999,
    height: 10,
    width: 10,
  },
  statusDotConnected: {
    backgroundColor: '#66E0B2',
  },
  statusDotBusy: {
    backgroundColor: '#79EFF7',
  },
  statusDotWarning: {
    backgroundColor: '#F3C969',
  },
  statusText: {
    color: '#EAF3F5',
    fontSize: 15,
    fontWeight: '600',
    letterSpacing: 0.2,
  },
  portalStage: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
    minHeight: 280,
    paddingTop: 86,
  },
  portalFrame: {
    alignItems: 'center',
    backgroundColor: 'rgba(174, 207, 216, 0.26)',
    borderColor: 'rgba(132, 239, 250, 0.82)',
    borderRadius: 95,
    borderWidth: 2,
    height: 190,
    justifyContent: 'center',
    shadowColor: '#22D3EE',
    shadowOffset: { height: 0, width: 0 },
    shadowOpacity: 0.22,
    shadowRadius: 18,
    width: 190,
  },
  portalFrameConnected: {
    backgroundColor: 'rgba(50, 150, 124, 0.27)',
    borderColor: 'rgba(102, 224, 178, 0.9)',
    shadowColor: '#55D6A9',
  },
  portalFrameWarning: {
    borderColor: 'rgba(243, 201, 105, 0.88)',
    shadowColor: '#F3C969',
  },
  portalButton: {
    alignItems: 'center',
    borderRadius: 91,
    height: 182,
    justifyContent: 'center',
    paddingHorizontal: 22,
    width: 182,
  },
  portalPressed: {
    backgroundColor: 'rgba(121, 239, 247, 0.13)',
  },
  portalDisabled: {
    opacity: 0.48,
  },
  shieldIcon: {
    alignItems: 'center',
    height: 54,
    justifyContent: 'center',
    position: 'relative',
    width: 60,
  },
  powerIcon: {
    position: 'absolute',
  },
  portalAction: {
    color: '#F4FCFD',
    fontSize: 19,
    fontWeight: '700',
    marginTop: 8,
    textAlign: 'center',
  },
  portalHelper: {
    color: 'rgba(226, 241, 244, 0.74)',
    fontSize: 13,
    lineHeight: 17,
    marginTop: 4,
    maxWidth: 168,
    textAlign: 'center',
  },
  footer: {
    gap: 10,
  },
  notices: {
    gap: 8,
  },
  locationButton: {
    alignItems: 'center',
    backgroundColor: 'transparent',
    borderRadius: 18,
    flexDirection: 'row',
    gap: 14,
    minHeight: 88,
    paddingHorizontal: 14,
    paddingVertical: 12,
  },
  locationPressed: {
    backgroundColor: 'rgba(10, 43, 52, 0.32)',
  },
  flagDisc: {
    alignItems: 'center',
    backgroundColor: 'rgba(5, 25, 33, 0.7)',
    borderColor: 'rgba(255,255,255,0.16)',
    borderRadius: 28,
    borderWidth: StyleSheet.hairlineWidth,
    height: 56,
    justifyContent: 'center',
    width: 56,
  },
  flag: {
    fontSize: 31,
  },
  locationCopy: {
    flex: 1,
    minWidth: 0,
  },
  locationTitleRow: {
    alignItems: 'center',
    flexDirection: 'row',
  },
  locationTitle: {
    color: '#F4FCFD',
    flexShrink: 1,
    fontSize: 25,
    fontWeight: '600',
    letterSpacing: -0.35,
  },
  locationMeta: {
    color: 'rgba(205, 229, 233, 0.78)',
    fontSize: 15,
    marginTop: 3,
  },
});

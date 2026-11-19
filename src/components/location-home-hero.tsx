import { ChevronRight, MapPin, Power, Settings, Shield } from 'lucide-react-native';
import type { ReactNode } from 'react';
import {
  type Animated,
  ImageBackground,
  type ImageSourcePropType,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { VpnLocation } from '@/api/vexApi';
import { VexWordmark } from '@/components/vex-wordmark';
import { VexPressable } from '@/ui/vex-ui';
import type { ConnectionPhase } from '@/screens/home-screen-helpers';
import type { ServerSelectionMode } from '@/vpn/serverSelection';
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
  ru: require('../../assets/locations/moscow-ru.png') as ImageSourcePropType,
};

type LocationHomeHeroProps = {
  accountTierLabel?: string;
  children?: ReactNode;
  connectionPhase: ConnectionPhase;
  headerActions?: ReactNode;
  location?: VpnLocation;
  latencyText: string;
  onLocationPress: () => void;
  onPowerPress: () => void;
  onSettingsPress: () => void;
  powerButtonDisabled: boolean;
  protocolLabel?: 'AWG' | 'VLESS';
  pulseProgress: Animated.Value;
  selectionMode: ServerSelectionMode;
};

export function LocationHomeHero({
  accountTierLabel,
  children,
  connectionPhase,
  headerActions,
  location,
  latencyText,
  onLocationPress,
  onPowerPress,
  onSettingsPress,
  powerButtonDisabled,
  protocolLabel,
  selectionMode,
}: LocationHomeHeroProps) {
  const safeAreaInsets = useSafeAreaInsets();
  const { width, height, fontScale } = useWindowDimensions();
  const largeText = fontScale > 1.3;
  const compact = height < 600;
  const availableWidth = Math.max(0, width - (safeAreaInsets.left ?? 0) - (safeAreaInsets.right ?? 0) - 48);
  const adaptivePower = largeText || availableWidth < 192;
  const presentation = homeConnectionPresentation(connectionPhase);
  const activationPending = connectionPhase === 'connecting' || connectionPhase === 'verifying';
  const powerActionLabel = connectionPhase === 'connecting' ? 'Отменить подключение'
    : activationPending ? presentation.helper : presentation.action;
  const locationCopy = location ? homeLocationCopy(location, latencyText, selectionMode) : null;
  const backgroundSource = locationBackgrounds[homeLocationBackdropKey(location)];

  const content = (
    <View
      style={[
        styles.root,
        {
          paddingBottom: Math.max(safeAreaInsets.bottom, 24),
          paddingTop: safeAreaInsets.top,
          paddingLeft: 24 + (safeAreaInsets.left ?? 0),
          paddingRight: 24 + (safeAreaInsets.right ?? 0),
          ...(compact ? { minHeight: height } : null),
        },
      ]}
    >
      <View pointerEvents="none" style={styles.photoShade} />
      <View style={styles.header}>
        <View accessibilityLabel="VEX VPN" pointerEvents="none" style={largeText ? styles.adaptiveBrand : styles.brand}>
          <VexWordmark accessibilityHidden />
          {accountTierLabel ? <Text style={styles.brandTier}>· {accountTierLabel}</Text> : null}
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
            <Settings color="#B7C0C3" size={20} strokeWidth={1.75} />
          </VexPressable>
        </View>
      </View>

      <View style={[styles.portalStage, compact && styles.compactPortalStage]}>
        <View
          style={[
            styles.portalFrame,
            adaptivePower && [styles.adaptivePortalFrame, { width: Math.min(320, availableWidth) }],
            presentation.tone === 'connected' && styles.portalFrameConnected,
            presentation.tone === 'warning' && styles.portalFrameWarning,
          ]}
        >
          <VexPressable
            accessibilityLabel={powerActionLabel}
            accessibilityRole="button"
            accessibilityState={{ busy: activationPending, disabled: powerButtonDisabled }}
            disabled={powerButtonDisabled}
            hoverStyle={styles.portalPressed}
            onPress={onPowerPress}
            style={[styles.portalButton, adaptivePower && styles.adaptivePortalButton, powerButtonDisabled && !activationPending && styles.portalDisabled]}
            title={powerActionLabel}
          >
            <View pointerEvents="none" style={styles.shieldIcon}>
              <Shield color="#43D9E7" size={56} strokeWidth={1.75} />
              <Power color="#43D9E7" size={24} strokeWidth={1.75} style={styles.powerIcon} />
            </View>
            <Text style={styles.portalAction}>{presentation.action}</Text>
            <Text style={styles.portalHelper}>{presentation.helper}</Text>
          </VexPressable>
        </View>
      </View>

      <View style={styles.footer}>
        {children ? <View style={styles.notices}>{children}</View> : null}
        <VexPressable
          accessibilityLabel={`${locationCopy ? `Выбрать локацию. Сейчас ${locationCopy.city}` : 'Выбрать локацию'}${protocolLabel ? `. Выбранный протокол: ${protocolLabel}` : ''}`}
          accessibilityRole="button"
          disabled={powerButtonDisabled && !location}
          hoverStyle={styles.locationPressed}
          onPress={onLocationPress}
          style={styles.locationButton}
          title="Выбрать локацию"
        >
          <View pointerEvents="none" style={styles.locationIcon}>
            <MapPin color="#B7C0C3" size={20} strokeWidth={1.75} />
          </View>
          <View style={styles.locationCopy}>
            <View style={styles.locationTitleRow}>
              <Text style={styles.locationTitle}>{locationCopy?.city ?? 'Локация не выбрана'}</Text>
              <ChevronRight color="#B7C0C3" size={20} strokeWidth={1.75} />
            </View>
            <View style={styles.locationMetaRow}>
              <Text style={styles.locationMeta}>
                {locationCopy?.countryAndLatency ?? 'Выберите доступный сервер'}
                {protocolLabel ? ' · ' : ''}
                {protocolLabel ? <Text testID="home-selected-protocol" style={styles.protocolLabel}>{protocolLabel}</Text> : null}
              </Text>
            </View>
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
    flexGrow: 1,
    width: '100%',
  },
  fallbackBackground: {
    backgroundColor: '#111416',
    flexGrow: 1,
    width: '100%',
  },
  root: {
    flexGrow: 1,
    minHeight: 640,
    paddingBottom: 24,
    paddingHorizontal: 24,
  },
  photoShade: {
    backgroundColor: 'rgba(7, 10, 12, 0.3)',
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
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'center',
    left: 0,
    position: 'absolute',
    right: 0,
  },
  adaptiveBrand: {
    alignItems: 'center',
    flex: 1,
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  brandTier: {
    color: '#B7C0C3',
    fontSize: 12,
    fontWeight: '500',
  },
  headerActions: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
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
  portalStage: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
    minHeight: 280,
    paddingTop: 40,
  },
  compactPortalStage: {
    minHeight: 216,
    paddingTop: 0,
  },
  adaptivePortalFrame: {
    borderRadius: 32,
    height: 'auto',
    minHeight: 192,
    padding: 4,
  },
  adaptivePortalButton: {
    borderRadius: 28,
    height: 'auto',
    minHeight: 184,
    paddingVertical: 24,
    width: '100%',
  },
  portalFrame: {
    alignItems: 'center',
    backgroundColor: 'rgba(17, 20, 22, 0.96)',
    borderColor: 'rgba(242, 245, 245, 0.16)',
    borderRadius: 96,
    borderWidth: 1,
    height: 192,
    justifyContent: 'center',
    width: 192,
  },
  portalFrameConnected: {
    borderColor: 'rgba(85, 214, 169, 0.5)',
  },
  portalFrameWarning: {
    borderColor: 'rgba(243, 201, 105, 0.5)',
  },
  portalButton: {
    alignItems: 'center',
    borderRadius: 92,
    height: 184,
    justifyContent: 'center',
    paddingHorizontal: 24,
    width: 184,
  },
  portalPressed: {
    backgroundColor: 'rgba(242, 245, 245, 0.06)',
  },
  portalDisabled: {
    opacity: 0.48,
  },
  shieldIcon: {
    alignItems: 'center',
    height: 56,
    justifyContent: 'center',
    position: 'relative',
    width: 60,
  },
  powerIcon: {
    position: 'absolute',
  },
  portalAction: {
    color: '#F4FCFD',
    fontSize: 20,
    fontWeight: '600',
    marginTop: 8,
    textAlign: 'center',
  },
  portalHelper: {
    color: '#B7C0C3',
    fontSize: 14,
    lineHeight: 20,
    marginTop: 4,
    maxWidth: 168,
    textAlign: 'center',
  },
  footer: {
    gap: 12,
  },
  notices: {
    gap: 8,
  },
  locationButton: {
    alignItems: 'center',
    backgroundColor: 'transparent',
    borderRadius: 16,
    flexDirection: 'row',
    gap: 16,
    minHeight: 88,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  locationPressed: {
    backgroundColor: 'rgba(17, 20, 22, 0.5)',
  },
  locationIcon: {
    alignItems: 'center',
    height: 48,
    justifyContent: 'center',
    width: 24,
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
    fontSize: 24,
    fontWeight: '500',
  },
  locationMetaRow: {
    alignItems: 'center',
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: 8,
    rowGap: 4,
    marginTop: 4,
  },
  locationMeta: {
    color: '#B7C0C3',
    flexShrink: 1,
    fontSize: 15,
    lineHeight: 20,
    fontVariant: ['tabular-nums'],
  },
  protocolLabel: {
    color: '#B7C0C3',
    fontSize: 15,
    fontWeight: '500',
  },
});

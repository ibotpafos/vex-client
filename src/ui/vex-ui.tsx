import React, { useEffect, useState, type PropsWithChildren } from 'react';
import { ImageBackground, Platform, StyleSheet, useWindowDimensions, View, type ViewStyle } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

const networkMap = require('../../assets/vex-network-map.png');

export const vexMaxContentWidth = 430;

export const vexColors = {
  accent: '#22D3EE',
  background: '#020A0B',
  card: 'rgba(7,17,19,0.88)',
  cardSoft: 'rgba(7,17,19,0.86)',
  field: 'rgba(2,10,11,0.78)',
  line: 'rgba(96,118,123,0.42)',
  lineStrong: 'rgba(96,118,123,0.46)',
  muted: '#A7B9BD',
  text: '#F4FCFD',
  textSoft: '#EAF7F8',
  danger: '#FF9F9F',
  dangerSoft: 'rgba(255,122,122,0.08)',
  dangerLine: 'rgba(255,122,122,0.34)',
};

type VexScreenProps = PropsWithChildren<{
  contentStyle?: ViewStyle;
}>;

export function VexScreen({ children, contentStyle }: VexScreenProps) {
  const { width: viewportWidth } = useWindowDimensions();
  const contentWidth = Math.min(viewportWidth - 24, vexMaxContentWidth);
  const [showBackgroundMap, setShowBackgroundMap] = useState(Platform.OS !== 'android');

  useEffect(() => {
    if (showBackgroundMap) {
      return undefined;
    }
    const timer = setTimeout(() => setShowBackgroundMap(true), 700);
    return () => clearTimeout(timer);
  }, [showBackgroundMap]);

  return (
    <View style={vexSharedStyles.screen}>
      {showBackgroundMap ? (
        <ImageBackground source={networkMap} resizeMode="cover" style={vexSharedStyles.backgroundMap} imageStyle={vexSharedStyles.backgroundMapImage as any}>
          <View style={vexSharedStyles.backgroundOverlay} />
        </ImageBackground>
      ) : null}
      <SafeAreaView edges={['top', 'bottom']} style={vexSharedStyles.safeLayer}>
        <View style={[vexSharedStyles.shell, { width: contentWidth }, contentStyle]}>
          {children}
        </View>
      </SafeAreaView>
    </View>
  );
}

export const vexSharedStyles = StyleSheet.create({
  screen: {
    backgroundColor: vexColors.background,
    flex: 1,
  },
  safeLayer: {
    alignItems: 'center',
    backgroundColor: 'transparent',
    flex: 1,
  },
  backgroundMap: {
    ...StyleSheet.absoluteFill,
    opacity: 0.28,
  },
  backgroundMapImage: {
    transform: [{ scale: 1.18 }],
  },
  backgroundOverlay: {
    backgroundColor: 'rgba(2,10,11,0.78)',
    flex: 1,
  },
  shell: {
    alignSelf: 'center',
    flex: 1,
    gap: 10,
    paddingBottom: 12,
    paddingTop: 0,
  },
  topBar: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 46,
  },
  iconButton: {
    alignItems: 'center',
    height: 42,
    justifyContent: 'center',
    width: 42,
  },
  title: {
    color: vexColors.text,
    fontSize: 18,
    fontWeight: '900',
  },
  card: {
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 24,
    borderWidth: 1,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: vexColors.accent,
    borderRadius: 14,
    justifyContent: 'center',
    minHeight: 50,
  },
  primaryButtonText: {
    color: '#031012',
    fontSize: 18,
    fontWeight: '900',
  },
  busy: {
    opacity: 0.72,
  },
});

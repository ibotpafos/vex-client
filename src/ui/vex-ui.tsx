import React, { useEffect, useState, type PropsWithChildren } from 'react';
import { ImageBackground, Platform, Pressable, StyleSheet, useWindowDimensions, View, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { vexTheme } from '@/ui/vex-theme';

const networkMap = require('../../assets/vex-network-map.png');

export const vexMaxContentWidth = 430;

export const vexColors = {
  accent: vexTheme.colors.accent,
  background: vexTheme.colors.background,
  card: vexTheme.colors.surface,
  cardSoft: vexTheme.colors.surfaceMuted,
  field: vexTheme.colors.field,
  line: vexTheme.colors.line,
  lineStrong: vexTheme.colors.lineStrong,
  muted: vexTheme.colors.textMuted,
  text: vexTheme.colors.text,
  textSoft: vexTheme.colors.textSecondary,
  danger: vexTheme.colors.danger,
  dangerSoft: vexTheme.colors.dangerMuted,
  dangerLine: vexTheme.colors.dangerLine,
};

type VexScreenProps = PropsWithChildren<{
  backgroundMapEnabled?: boolean;
  contentStyle?: ViewStyle;
}>;

export function VexScreen({ children, contentStyle, backgroundMapEnabled = Platform.OS !== 'android' }: VexScreenProps) {
  const { width: viewportWidth } = useWindowDimensions();
  const horizontalInset = viewportWidth <= 360 ? 16 : 24;
  const contentWidth = Math.min(viewportWidth - horizontalInset, vexMaxContentWidth);
  const [showBackgroundMap, setShowBackgroundMap] = useState(backgroundMapEnabled);

  useEffect(() => {
    if (showBackgroundMap || !backgroundMapEnabled) {
      return undefined;
    }
    const timer = setTimeout(() => setShowBackgroundMap(true), 700);
    return () => clearTimeout(timer);
  }, [backgroundMapEnabled, showBackgroundMap]);

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
    opacity: 0.2,
  },
  backgroundMapImage: {
    transform: [{ scale: 1.18 }],
  },
  backgroundOverlay: {
    backgroundColor: 'rgba(4,11,13,0.84)',
    flex: 1,
  },
  shell: {
    alignSelf: 'center',
    flex: 1,
    gap: vexTheme.spacing.sm,
    paddingBottom: vexTheme.spacing.md,
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
    backgroundColor: vexTheme.colors.surfaceMuted,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.md,
    borderWidth: 1,
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  iconButtonSpacer: {
    height: 44,
    width: 44,
  },
  title: {
    color: vexColors.text,
    fontSize: 18,
    fontWeight: '900',
  },
  card: {
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: vexTheme.radius.lg,
    borderWidth: 1,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: vexColors.accent,
    borderRadius: vexTheme.radius.md,
    justifyContent: 'center',
    minHeight: 52,
  },
  primaryButtonText: {
    color: '#031012',
    fontSize: vexTheme.type.body,
    fontWeight: '900',
  },
  busy: {
    opacity: 0.72,
  },
});

export interface VexPressableProps extends PressableProps {
  hoverStyle?: StyleProp<ViewStyle>;
  pointerCursor?: boolean;
  title?: string;
}

export function VexPressable({
  children,
  style,
  hoverStyle,
  pointerCursor = true,
  title,
  ...props
}: VexPressableProps) {
  return (
    <Pressable
      {...props}
      {...(Platform.OS === 'web' && title ? { title } : {})}
      style={(state) => {
        const resolvedStyle = typeof style === 'function' ? style(state) : style;
        const resolvedHoverStyle = (state as any).hovered ? hoverStyle : null;
        return [
          resolvedStyle,
          resolvedHoverStyle,
          Platform.OS === 'web' && pointerCursor && { cursor: 'pointer' } as any,
        ];
      }}
    >
      {children}
    </Pressable>
  );
}

import { type PropsWithChildren } from 'react';
import React from 'react';
import { Platform, Pressable, StyleSheet, useWindowDimensions, View, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

import { vexTheme } from '@/ui/vex-theme';

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
  contentStyle?: ViewStyle;
}>;

export function VexScreen({ children, contentStyle }: VexScreenProps) {
  const { width: viewportWidth } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const availableWidth = Math.max(0, viewportWidth - insets.left - insets.right);
  const horizontalInset = viewportWidth <= 360 ? 16 : 24;
  const contentWidth = Math.max(0, Math.min(availableWidth - horizontalInset, vexMaxContentWidth));

  return (
    <View style={vexSharedStyles.screen}>
      <SafeAreaView edges={['top', 'bottom', 'left', 'right']} style={vexSharedStyles.safeLayer}>
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
  shell: {
    alignSelf: 'center',
    flex: 1,
    gap: vexTheme.spacing.md,
    paddingBottom: vexTheme.spacing.lg,
    paddingTop: 0,
  },
  topBar: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.lg,
    borderWidth: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 56,
    paddingHorizontal: 8,
  },
  iconButton: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.surfaceMuted,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.md,
    borderWidth: 1,
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  iconButtonSpacer: {
    height: 48,
    width: 48,
  },
  title: {
    color: vexColors.text,
    fontSize: 18,
    fontWeight: '600',
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
    fontWeight: '600',
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

export const VexPressable = React.memo(function VexPressable({
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
});

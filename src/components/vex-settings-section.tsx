import type { ReactNode } from 'react';
import { StyleSheet, Text, View, type AccessibilityRole, type AccessibilityState } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';
import { VexPressable } from '@/ui/vex-ui';
import { vexMobileSurface, vexMobileType } from '@/ui/vex-mobile-visual';

export function VexSection({ children, title }: { children: ReactNode; title: string }) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      <View style={styles.surface}>{children}</View>
    </View>
  );
}

type VexSettingsRowProps = {
  accessibilityRole?: AccessibilityRole;
  accessibilityState?: AccessibilityState;
  accessory?: ReactNode;
  description?: string;
  disabled?: boolean;
  icon?: ReactNode;
  onPress?: () => void;
  title: string;
  value?: string;
};

export function VexSettingsRow({
  accessibilityRole,
  accessibilityState,
  accessory,
  description,
  disabled,
  icon,
  onPress,
  title,
  value,
}: VexSettingsRowProps) {
  const content = (
    <>
      {icon ? <View style={styles.icon}>{icon}</View> : null}
      <View style={styles.copy}>
        <Text style={styles.rowTitle}>{title}</Text>
        {description ? <Text style={styles.description}>{description}</Text> : null}
        {value ? <Text style={styles.value}>{value}</Text> : null}
      </View>
      {accessory}
    </>
  );

  if (!onPress) return <View style={styles.row}>{content}</View>;

  return (
    <VexPressable
      accessibilityLabel={title}
      accessibilityRole={accessibilityRole ?? 'button'}
      accessibilityState={accessibilityState}
      disabled={disabled}
      hoverStyle={styles.pressed}
      onPress={onPress}
      style={[styles.row, disabled && styles.disabled]}
    >
      {content}
    </VexPressable>
  );
}

const styles = StyleSheet.create({
  copy: { flex: 1, minWidth: 0 },
  description: { color: vexTheme.colors.textMuted, marginTop: 3, ...vexMobileType.metadata },
  disabled: { opacity: 0.55 },
  icon: { alignItems: 'center', justifyContent: 'center', width: 34 },
  pressed: { backgroundColor: vexMobileSurface.pressed },
  row: {
    alignItems: 'center',
    borderBottomColor: vexMobileSurface.divider,
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    gap: 12,
    minHeight: 68,
    paddingHorizontal: 14,
    paddingVertical: 11,
  },
  rowTitle: { color: vexTheme.colors.text, ...vexMobileType.rowTitle },
  section: { gap: 8 },
  sectionTitle: {
    color: vexTheme.colors.textMuted,
    paddingHorizontal: 4,
    textTransform: 'uppercase',
    ...vexMobileType.sectionTitle,
  },
  surface: {
    backgroundColor: vexMobileSurface.grouped,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
  },
  value: { color: vexTheme.colors.accent, marginTop: 4, ...vexMobileType.metadata },
});

import React, { type ReactElement } from 'react';
import { Image, StyleSheet, Text, View, type ImageSourcePropType } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';

type HomeNativeHeaderProps = {
  logoSource: ImageSourcePropType;
  planLabel: string | null;
  showPlan: boolean;
  actions: ReactElement;
};

export function HomeNativeHeader({ logoSource, planLabel, showPlan, actions }: HomeNativeHeaderProps) {
  return (
    <View style={styles.topBar}>
      <View style={styles.brandGroup}>
        <View style={styles.brandBadge}>
          <Image source={logoSource} resizeMode="contain" style={styles.brandLogo} />
        </View>
        <View style={styles.brandTitleRow}>
          <Text style={styles.brandText}>VEX</Text>
          {showPlan && planLabel ? (
            <View style={styles.headerPlanChip}>
              <Text style={styles.headerPlanChipText}>{planLabel}</Text>
            </View>
          ) : null}
        </View>
      </View>
      {actions}
    </View>
  );
}

const styles = StyleSheet.create({
  topBar: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 58,
  },
  brandGroup: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
    minWidth: 0,
  },
  brandBadge: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.surfaceMuted,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.md,
    borderWidth: 1,
    height: 46,
    justifyContent: 'center',
    width: 46,
  },
  brandLogo: {
    height: 38,
    width: 38,
  },
  brandTitleRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minWidth: 0,
  },
  brandText: {
    color: vexTheme.colors.text,
    fontSize: 26,
    fontWeight: '900',
    letterSpacing: 0,
  },
  headerPlanChip: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.accentMuted,
    borderColor: vexTheme.colors.accentLine,
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 25,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  headerPlanChipText: {
    color: vexTheme.colors.accentStrong,
    fontSize: 12,
    fontWeight: '900',
  },
});

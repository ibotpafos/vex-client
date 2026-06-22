import React, { type ReactElement } from 'react';
import { Image, StyleSheet, Text, View, type ImageSourcePropType } from 'react-native';

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
    minHeight: 46,
  },
  brandGroup: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
    minWidth: 0,
  },
  brandBadge: {
    alignItems: 'center',
    height: 52,
    justifyContent: 'center',
    overflow: 'visible',
    width: 56,
  },
  brandLogo: {
    height: 52,
    width: 52,
  },
  brandTitleRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minWidth: 0,
  },
  brandText: {
    color: '#F4FCFD',
    fontSize: 28,
    fontWeight: '900',
    letterSpacing: 0,
  },
  headerPlanChip: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.14)',
    borderColor: 'rgba(34,211,238,0.34)',
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 25,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  headerPlanChipText: {
    color: '#22D3EE',
    fontSize: 12,
    fontWeight: '900',
  },
});

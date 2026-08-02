import React, { type ReactElement } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';

type HomeNativeHeaderProps = {
  actions: ReactElement;
};

export function HomeNativeHeader({ actions }: HomeNativeHeaderProps) {
  return (
    <View style={styles.topBar}>
      <View style={styles.brandGroup}>
        <Text style={styles.brandText}>VEX</Text>
        <View style={styles.brandDot} />
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
  },
  brandText: {
    color: vexTheme.colors.text,
    fontSize: 28,
    fontWeight: '900',
    letterSpacing: 0,
  },
  brandDot: {
    backgroundColor: vexTheme.colors.accent,
    borderRadius: 999,
    height: 11,
    marginTop: 4,
    width: 11,
  },
});

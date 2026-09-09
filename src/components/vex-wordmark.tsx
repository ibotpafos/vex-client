import { StyleSheet, Text } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';
import { vexMobileType } from '@/ui/vex-mobile-visual';

type VexWordmarkProps = {
  accessibilityHidden?: boolean;
  size?: 'compact' | 'display';
};

export function VexWordmark({ accessibilityHidden = false, size = 'compact' }: VexWordmarkProps) {
  return (
    <Text
      accessibilityElementsHidden={accessibilityHidden}
      accessibilityLabel={accessibilityHidden ? undefined : 'VEX VPN'}
      accessible={!accessibilityHidden}
      importantForAccessibility={accessibilityHidden ? 'no-hide-descendants' : 'yes'}
      style={[styles.wordmark, size === 'display' && styles.display]}
    >
      VEX
    </Text>
  );
}

const styles = StyleSheet.create({
  display: {
    fontSize: 32,
    letterSpacing: 10,
  },
  wordmark: {
    color: vexTheme.colors.text,
    ...vexMobileType.wordmark,
  },
});

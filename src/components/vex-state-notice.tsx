import { StyleSheet, Text, View } from 'react-native';

import { vexTheme } from '@/ui/vex-theme';
import {
  mobileStateNoticePresentation,
  type MobileNoticeTone,
  vexMobileSurface,
  vexMobileType,
} from '@/ui/vex-mobile-visual';

type VexStateNoticeProps = {
  message: string;
  tone: MobileNoticeTone;
};

export function VexStateNotice({ message, tone }: VexStateNoticeProps) {
  const presentation = mobileStateNoticePresentation(tone);

  return (
    <View
      accessibilityLiveRegion={tone === 'error' || tone === 'warning' ? 'assertive' : 'polite'}
      accessibilityRole={presentation.accessibilityRole}
      style={[styles.notice, { borderLeftColor: presentation.accent }]}
    >
      <Text style={styles.message}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  message: {
    color: vexTheme.colors.textSecondary,
    ...vexMobileType.metadata,
  },
  notice: {
    backgroundColor: vexMobileSurface.grouped,
    borderLeftWidth: 2,
    borderRadius: vexTheme.radius.sm,
    paddingHorizontal: 14,
    paddingVertical: 12,
  },
});

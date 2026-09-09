import { ChevronLeft } from 'lucide-react-native';
import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { playSelectionHaptic } from '@/native/haptics';
import { vexTheme } from '@/ui/vex-theme';
import { VexPressable, VexScreen } from '@/ui/vex-ui';
import { vexMobileSpacing, vexMobileType } from '@/ui/vex-mobile-visual';

type MobileScreenHeaderProps = {
  onBack?: () => void;
  title?: string;
  trailing?: ReactNode;
};

export function MobileScreenHeader({ onBack, title, trailing }: MobileScreenHeaderProps) {
  return (
    <View style={styles.header}>
      {onBack ? (
        <VexPressable
          accessibilityLabel="Назад"
          accessibilityRole="button"
          hitSlop={10}
          onPress={() => {
            playSelectionHaptic();
            onBack();
          }}
          style={styles.headerAction}
        >
          <ChevronLeft color={vexTheme.colors.text} size={27} strokeWidth={2.2} />
        </VexPressable>
      ) : <View style={styles.headerAction} />}
      {title ? <Text numberOfLines={1} style={styles.title}>{title}</Text> : <View />}
      <View style={styles.headerAction}>{trailing}</View>
    </View>
  );
}

type MobileScreenScaffoldProps = MobileScreenHeaderProps & {
  children: ReactNode;
  scroll?: boolean;
};

export function MobileScreenScaffold({ children, onBack, scroll = false, title, trailing }: MobileScreenScaffoldProps) {
  const content = (
    <>
      {(title || onBack || trailing) ? <MobileScreenHeader onBack={onBack} title={title} trailing={trailing} /> : null}
      {children}
    </>
  );

  return (
    <VexScreen contentStyle={styles.screenContent}>
      {scroll ? (
        <ScrollView
          alwaysBounceVertical={false}
          contentContainerStyle={styles.scrollContent}
          showsVerticalScrollIndicator={false}
        >
          {content}
        </ScrollView>
      ) : content}
    </VexScreen>
  );
}

const styles = StyleSheet.create({
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 56,
  },
  headerAction: {
    alignItems: 'center',
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  screenContent: {
    gap: 0,
    paddingHorizontal: vexMobileSpacing.screen,
  },
  scrollContent: {
    gap: vexMobileSpacing.section,
    paddingBottom: vexMobileSpacing.screen,
  },
  title: {
    color: vexTheme.colors.text,
    flex: 1,
    textAlign: 'center',
    ...vexMobileType.rowTitle,
  },
});

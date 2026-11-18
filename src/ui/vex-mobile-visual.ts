import { vexTheme } from '@/ui/vex-theme';

export type MobileNoticeTone = 'loading' | 'warning' | 'error' | 'success';

export const vexMobileType = {
  wordmark: { fontSize: 25, fontWeight: '700' as const, letterSpacing: 8 },
  screenTitle: { fontSize: 28, fontWeight: '500' as const, letterSpacing: 0 },
  sectionTitle: { fontSize: 13, fontWeight: '500' as const, letterSpacing: 0 },
  rowTitle: { fontSize: 16, fontWeight: '500' as const },
  body: { fontSize: 15, lineHeight: 21 },
  metadata: { fontSize: 13, lineHeight: 18 },
} as const;

export const vexMobileSpacing = {
  compactScreen: 16,
  row: 16,
  screen: 24,
  section: 24,
} as const;

export const vexMobileSurface = {
  background: vexTheme.colors.background,
  divider: vexTheme.colors.line,
  grouped: vexTheme.colors.surface,
  pressed: vexTheme.colors.surfaceRaised,
} as const;

export function mobileStateNoticePresentation(tone: MobileNoticeTone) {
  return {
    accent: tone === 'error'
      ? vexTheme.colors.danger
      : tone === 'warning'
        ? vexTheme.colors.warning
        : tone === 'success'
          ? vexTheme.colors.success
          : vexTheme.colors.accent,
    accessibilityRole: tone === 'error' ? 'alert' as const : 'text' as const,
  };
}

import { vexTheme } from '@/ui/vex-theme';

export type MobileNoticeTone = 'loading' | 'warning' | 'error' | 'success';

export const vexMobileType = {
  wordmark: { fontSize: 25, fontWeight: '700' as const, letterSpacing: 8 },
  screenTitle: { fontSize: 28, fontWeight: '700' as const, letterSpacing: -0.5 },
  sectionTitle: { fontSize: 13, fontWeight: '700' as const, letterSpacing: 0.5 },
  rowTitle: { fontSize: 16, fontWeight: '600' as const },
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
  background: '#041315',
  divider: 'rgba(159, 218, 223, 0.16)',
  grouped: 'rgba(5, 22, 25, 0.92)',
  pressed: 'rgba(67, 217, 231, 0.09)',
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

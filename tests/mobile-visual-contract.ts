import {
  mobileStateNoticePresentation,
  vexMobileType,
} from '../src/ui/vex-mobile-visual';
import { homeBrandPresentation } from '../src/screens/home-screen-visual';

assertDeepEqual(mobileStateNoticePresentation('error'), {
  accent: '#FF9EAA',
  accessibilityRole: 'alert',
});
assertDeepEqual(mobileStateNoticePresentation('success'), {
  accent: '#55D6A9',
  accessibilityRole: 'text',
});
assertEqual(vexMobileType.wordmark.letterSpacing, 8);
assertEqual(vexMobileType.wordmark.fontWeight, '700');
assertDeepEqual(homeBrandPresentation(), {
  accessibilityLabel: 'VEX VPN',
  usesEmblem: false,
  wordmark: 'VEX',
});

function assertEqual<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertDeepEqual<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

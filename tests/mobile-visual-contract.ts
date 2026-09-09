import {
  mobileStateNoticePresentation,
  vexMobileType,
} from '../src/ui/vex-mobile-visual';

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

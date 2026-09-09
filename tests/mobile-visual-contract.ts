import {
  mobileStateNoticePresentation,
  vexMobileType,
} from '../src/ui/vex-mobile-visual';
import { homeBrandPresentation } from '../src/screens/home-screen-visual';
import { serverPickerRowPresentation } from '../src/screens/server-picker-interactions';
import type { VpnLocation } from '../src/api/vexApi';
import { settingsSectionModel } from '../src/screens/settings-screen-copy';
import {
  applicationSelectionSummary,
  updateStatusHierarchy,
} from '../src/screens/mobile-utility-visual';

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
const germanyLocation: VpnLocation = {
  availability: 'available',
  city: 'Frankfurt',
  countryCode: 'DE',
  flagEmoji: '🇩🇪',
  healthyNodes: 1,
  id: 'de',
  latencyMs: 18,
  status: 'healthy',
};
assertDeepEqual(serverPickerRowPresentation(germanyLocation, {
  busy: false,
  selected: true,
  selectedLatencyText: '7 мс',
}), {
  accessibilityLabel: 'Германия, 7 мс, выбрано',
  disabled: false,
  latency: '7 мс',
  selected: true,
});
assertDeepEqual(settingsSectionModel('ios').map((section) => section.id), [
  'connection',
  'routing',
  'interface',
  'account',
  'about',
]);
assertEqual(
  settingsSectionModel('ios').flatMap((section) => section.rows).includes('applications'),
  false,
);
assertEqual(
  settingsSectionModel('android').flatMap((section) => section.rows).includes('applications'),
  true,
);
assertEqual(applicationSelectionSummary('all', 0), 'Все приложения');
assertEqual(applicationSelectionSummary('selected', 3), 'Выбрано: 3');
assertDeepEqual(updateStatusHierarchy({ required: true, available: true }), {
  actionPriority: 'primary',
  tone: 'warning',
});
assertDeepEqual(updateStatusHierarchy({ required: false, available: false }), {
  actionPriority: 'secondary',
  tone: 'success',
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

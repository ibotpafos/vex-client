import {
  mobileStateNoticePresentation,
  vexMobileType,
} from '../src/ui/vex-mobile-visual';
import { homeBrandPresentation, homeLocationCopy } from '../src/screens/home-screen-visual';
import {
  groupVpnLocationsByCountry,
  serverCountLabel,
  serverPickerLocationTitle,
  serverPickerRowPresentation,
} from '../src/screens/server-picker-interactions';
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
assertDeepEqual(homeLocationCopy(germanyLocation, '18 мс', 'auto'), {
  city: 'Автоматически',
  countryAndLatency: 'Германия · Франкфурт · 18 мс',
});
assertDeepEqual(homeLocationCopy(germanyLocation, '18 мс', 'manual'), {
  city: 'Франкфурт',
  countryAndLatency: 'Германия · 18 мс',
});
assertDeepEqual(homeLocationCopy({ ...germanyLocation, city: 'VEX AWG 3.1 Features' }, '18 мс', 'auto'), {
  city: 'Автоматически',
  countryAndLatency: 'Германия · лучший сервер · 18 мс',
});
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
const germanyBackupLocation: VpnLocation = {
  ...germanyLocation,
  city: 'Berlin',
  healthyNodes: 2,
  id: 'de-berlin',
  latencyMs: 26,
};
const finlandLocation: VpnLocation = {
  ...germanyLocation,
  city: 'Helsinki',
  countryCode: 'FI',
  flagEmoji: '🇫🇮',
  id: 'fi-helsinki',
  latencyMs: 22,
};
assertDeepEqual(
  groupVpnLocationsByCountry([germanyBackupLocation, finlandLocation, germanyLocation]).map((group) => ({
    bestLocationId: group.bestLocation?.id,
    countryCode: group.countryCode,
    locationIds: group.locations.map((location) => location.id),
  })),
  [
    { bestLocationId: 'de', countryCode: 'DE', locationIds: ['de', 'de-berlin'] },
    { bestLocationId: 'fi-helsinki', countryCode: 'FI', locationIds: ['fi-helsinki'] },
  ],
);
assertEqual(serverCountLabel(1), '1 сервер');
assertEqual(serverCountLabel(2), '2 сервера');
assertEqual(serverCountLabel(5), '5 серверов');
assertEqual(serverCountLabel(11), '11 серверов');
assertEqual(serverPickerLocationTitle({ ...germanyLocation, city: 'Germany' }), 'Франкфурт');
assertEqual(serverPickerLocationTitle({ ...germanyLocation, city: 'VEX AWG 3.1 Features' }, 2), 'Сервер 2');
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

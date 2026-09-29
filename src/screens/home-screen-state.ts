import type { VpnLocation } from '@/api/vexApi';
import type { VpnStatus } from '@/native/vexVpn';
import { isSelectableLocation } from '@/vpn/serverSelection';

export function areVpnStatusesEqual(left: VpnStatus, right: VpnStatus) {
  return left.state === right.state
    && left.rxBytes === right.rxBytes
    && left.txBytes === right.txBytes
    && left.latestHandshakeEpochMillis === right.latestHandshakeEpochMillis
    && left.leakProtection === right.leakProtection
    && left.verified === right.verified
    && left.verificationReason === right.verificationReason;
}

export function vpnLocationFallbackFixturesEnabled(): boolean {
  const isDevelopment = typeof __DEV__ !== 'undefined' && __DEV__;
  return isDevelopment || process.env.NODE_ENV === 'test';
}

export function availableVpnLocations(
  locations?: VpnLocation[],
  allowFallbackFixtures = vpnLocationFallbackFixturesEnabled(),
): VpnLocation[] {
  const source = locations === undefined && allowFallbackFixtures ? fallbackVpnLocations : (locations ?? []);
  return source.filter(isSelectableLocation);
}

export function vpnPowerButtonDisabled(options: {
  canCancelConnecting: boolean;
  hasSelectedLocation: boolean;
  isConnected: boolean;
  isLeakBlocked: boolean;
  isVpnBusy: boolean;
}): boolean {
  return (options.isVpnBusy && !options.canCancelConnecting)
    || (!options.hasSelectedLocation && !options.isConnected && !options.isLeakBlocked);
}

export const fallbackVpnLocations: VpnLocation[] = [
  {
    id: 'de',
    countryCode: 'DE',
    city: 'Germany',
    flagEmoji: '🇩🇪',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
  {
    id: 'fi',
    countryCode: 'FI',
    city: 'Finland',
    flagEmoji: '🇫🇮',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
];

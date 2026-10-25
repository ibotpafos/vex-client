import type { VpnProfile } from './profile';
import type { VpnDevice } from '../api/types';
import { vpnProfileAddressMatchesDevice } from './profileConsistency';
import { isPositiveSafeInteger, isNonnegativeSafeInteger } from './profileNumbers';

export function profileRevalidationOptions(profile: VpnProfile | null | undefined, locationId: string, routingMode: VpnProfile['routingMode']) {
  if (!profile?.config || !profile.device?.id || profile.locationId !== locationId || profile.routingMode !== routingMode ||
      profile.rotationRequired || !isPositiveSafeInteger(profile.profileVersion) || !vpnProfileAddressMatchesDevice(profile)) return {};
  return {cachedConfig: profile.config, knownVersion: profile.profileVersion, cachedDevice: profile.device};
}

export function canRevalidateDevice(cached: VpnDevice | undefined, current: VpnDevice, publicKey: string): boolean {
  return Boolean(cached?.id && cached.id === current.id && publicKey && cached.publicKey === publicKey &&
    current.publicKey === publicKey && cached.keyEpoch === current.keyEpoch &&
    (cached.keyEpoch === undefined || isNonnegativeSafeInteger(cached.keyEpoch)));
}

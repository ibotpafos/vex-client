import type { VpnProfile } from './profile';
import type { ResolveConnectableProfileOptions } from './serverSwitch';

type FreshSameLocationProfileInput<TConnected> = {
  connectProfile: (profile: VpnProfile) => Promise<TConnected>;
  locationId: string;
  resolveProfile: (locationId: string, options: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
};

export async function connectFreshSameLocationProfile<TConnected>(
  input: FreshSameLocationProfileInput<TConnected>,
): Promise<TConnected> {
  const freshProfile = await input.resolveProfile(input.locationId, {
    forceRefresh: true,
    requestPermission: false,
  });
  return input.connectProfile(freshProfile);
}

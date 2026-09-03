import type { VpnProfile } from './profile';
import type { ResolveConnectableProfileOptions } from './serverSwitch';

type FreshSameLocationProfileInput<TConnected> = {
  connectProfile: (profile: VpnProfile) => Promise<TConnected>;
  locationId: string;
  resolveProfile: (locationId: string, options: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
};

type FallbackLocation = { id: string };

type FallbackLocationsInput<TConnected> = {
  connectProfile: (profile: VpnProfile) => Promise<TConnected>;
  excludedLocationId: string;
  isRetryableError: (error: unknown) => boolean;
  locations: readonly FallbackLocation[];
  resolveProfile: (locationId: string, options: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
};

export type FallbackLocationsResult<TConnected> = {
  connected: TConnected | null;
  lastError: unknown;
  locationId: string | null;
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

export async function connectAcrossFallbackLocations<TConnected>(
  input: FallbackLocationsInput<TConnected>,
): Promise<FallbackLocationsResult<TConnected>> {
  let lastError: unknown;

  for (const location of input.locations) {
    if (location.id === input.excludedLocationId) {
      continue;
    }

    let cachedProfile: VpnProfile | null = null;
    try {
      cachedProfile = await input.resolveProfile(location.id, {
        preferCached: true,
        requestPermission: false,
      });
    } catch (error) {
      lastError = error;
      if (!input.isRetryableError(error)) {
        throw error;
      }
    }

    if (cachedProfile) {
      try {
        return {
          connected: await input.connectProfile(cachedProfile),
          lastError: null,
          locationId: location.id,
        };
      } catch (error) {
        lastError = error;
        if (!input.isRetryableError(error)) {
          throw error;
        }
      }
    }

    try {
      const freshProfile = await input.resolveProfile(location.id, {
        forceRefresh: true,
        preferCached: false,
        requestPermission: false,
      });
      return {
        connected: await input.connectProfile(freshProfile),
        lastError: null,
        locationId: location.id,
      };
    } catch (error) {
      lastError = error;
      if (!input.isRetryableError(error)) {
        throw error;
      }
    }
  }

  return {
    connected: null,
    lastError,
    locationId: null,
  };
}

import type { VpnStatus } from '../native/vexVpn';
import type { VpnProfile } from './profile';

export type ResolveConnectableProfileOptions = {
  allowPersistentHotProfile?: boolean;
  cachedProfile?: VpnProfile | null;
  forceRefresh?: boolean;
  preferCached?: boolean;
  requestPermission?: boolean;
};

export type ConnectedVpnProfile = {
  profile: VpnProfile;
  status: VpnStatus;
};

export type SwitchVpnLocationInput = {
  cachedTargetProfile?: VpnProfile | null;
  connectProfile: (profile: VpnProfile) => Promise<ConnectedVpnProfile>;
  isRetryableConnectError: (error: unknown) => boolean;
  persistLocation: (locationId: string) => Promise<string>;
  previousLocationId: string;
  previousProfile: VpnProfile | null;
  previousStatus: VpnStatus;
  reportConnect?: (profile: VpnProfile) => void;
  reportDisconnect?: (profile: VpnProfile | null, reason: string) => void;
  resolveProfile: (locationId: string, options: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
  setCachedProfile: (locationId: string, profile: VpnProfile) => void;
  targetLocationId: string;
};

export type SwitchVpnLocationResult =
  | {
    ok: true;
    locationId: string;
    profile: VpnProfile;
    status: VpnStatus;
  }
  | {
    ok: false;
    error: unknown;
    profile: VpnProfile | null;
    rollback: 'not_started' | 'reconnected' | 'unavailable' | 'failed';
    rollbackError?: unknown;
    status: VpnStatus | null;
  };

export async function switchVpnLocation(input: SwitchVpnLocationInput): Promise<SwitchVpnLocationResult> {
  let targetConnectStarted = false;

  try {
    const targetProfile = await resolveTargetProfile(input);
    targetConnectStarted = true;
    const connectedTarget = await connectTargetProfile(input, targetProfile);

    const locationId = await input.persistLocation(input.targetLocationId);
    input.setCachedProfile(locationId, connectedTarget.profile);
    input.reportDisconnect?.(input.previousProfile, 'server_switch');
    input.reportConnect?.(connectedTarget.profile);

    return {
      ok: true,
      locationId,
      profile: connectedTarget.profile,
      status: connectedTarget.status,
    };
  } catch (error) {
    return rollbackToPreviousLocation(input, error, targetConnectStarted);
  }
}

async function resolveTargetProfile(input: SwitchVpnLocationInput): Promise<VpnProfile> {
  return input.resolveProfile(input.targetLocationId, {
    cachedProfile: input.cachedTargetProfile,
    forceRefresh: !input.cachedTargetProfile,
    requestPermission: false,
  });
}

async function connectTargetProfile(input: SwitchVpnLocationInput, targetProfile: VpnProfile): Promise<ConnectedVpnProfile> {
  try {
    return await input.connectProfile(targetProfile);
  } catch (error) {
    if (!input.cachedTargetProfile || !input.isRetryableConnectError(error)) {
      throw error;
    }
    const freshProfile = await input.resolveProfile(input.targetLocationId, {
      forceRefresh: true,
      requestPermission: false,
    });
    return input.connectProfile(freshProfile);
  }
}

async function rollbackToPreviousLocation(
  input: SwitchVpnLocationInput,
  error: unknown,
  targetConnectStarted: boolean,
): Promise<SwitchVpnLocationResult> {
  await input.persistLocation(input.previousLocationId).catch(() => undefined);
  if (input.previousProfile) {
    input.setCachedProfile(input.previousLocationId, input.previousProfile);
  }

  if (!targetConnectStarted) {
    return {
      ok: false,
      error,
      profile: input.previousProfile,
      rollback: 'not_started',
      status: input.previousStatus,
    };
  }

  if (!input.previousProfile?.config) {
    return {
      ok: false,
      error,
      profile: input.previousProfile,
      rollback: 'unavailable',
      status: null,
    };
  }

  try {
    const rollback = await input.connectProfile(input.previousProfile);
    input.setCachedProfile(input.previousLocationId, rollback.profile);
    input.reportConnect?.(rollback.profile);
    return {
      ok: false,
      error,
      profile: rollback.profile,
      rollback: 'reconnected',
      status: rollback.status,
    };
  } catch (rollbackError) {
    return {
      ok: false,
      error,
      profile: input.previousProfile,
      rollback: 'failed',
      rollbackError,
      status: null,
    };
  }
}

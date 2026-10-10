import type { VpnStatus } from '../native/vexVpn';
import type { VpnProfile } from './profile';
import { SessionOperationSupersededError } from './sessionOperation';

export type ResolveConnectableProfileOptions = {
  allowPersistentHotProfile?: boolean;
  cachedProfile?: VpnProfile | null;
  forceRefresh?: boolean;
  validateCachedProfile?: boolean;
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
  isCurrentSessionOperation?: () => boolean;
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
    requireCurrentSession(input);
    const targetProfile = await resolveTargetProfile(input);
    requireCurrentSession(input);
    targetConnectStarted = true;
    const connectedTarget = await connectTargetProfile(input, targetProfile);
    requireCurrentSession(input);

    const locationId = await input.persistLocation(input.targetLocationId);
    requireCurrentSession(input);
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
    // A superseded operation must never restore its old account's placement.
    // The new session owns the native tunnel, preferences and profile cache.
    requireCurrentSession(input);
    if (error instanceof SessionOperationSupersededError) throw error;
    return rollbackToPreviousLocation(input, error, targetConnectStarted);
  }
}

async function resolveTargetProfile(input: SwitchVpnLocationInput): Promise<VpnProfile> {
  return input.resolveProfile(input.targetLocationId, {
    // A location change also changes the server-side peer placement. Always
    // resolve that assignment before replacing the working tunnel; a cached
    // profile can contain an IP that is valid cryptographically but no longer
    // routed by the target node.
    forceRefresh: true,
    requestPermission: false,
  });
}

async function connectTargetProfile(input: SwitchVpnLocationInput, targetProfile: VpnProfile): Promise<ConnectedVpnProfile> {
  try {
    requireCurrentSession(input);
    const connected = await input.connectProfile(targetProfile);
    requireCurrentSession(input);
    return connected;
  } catch (error) {
    requireCurrentSession(input);
    if (error instanceof SessionOperationSupersededError) throw error;
    if (targetProfile.source !== 'local' || !input.isRetryableConnectError(error)) {
      throw error;
    }
    const freshProfile = await input.resolveProfile(input.targetLocationId, {
      forceRefresh: true,
      requestPermission: false,
    });
    requireCurrentSession(input);
    return input.connectProfile(freshProfile);
  }
}

async function rollbackToPreviousLocation(
  input: SwitchVpnLocationInput,
  error: unknown,
  targetConnectStarted: boolean,
): Promise<SwitchVpnLocationResult> {
  requireCurrentSession(input);
  await input.persistLocation(input.previousLocationId).catch((persistError) => {
    requireCurrentSession(input);
    if (persistError instanceof SessionOperationSupersededError) throw persistError;
  });
  requireCurrentSession(input);
  if (input.previousProfile) {
    input.setCachedProfile(input.previousLocationId, input.previousProfile);
  }

  // A failed profile fetch did not reach the native transition. Once target
  // issuance succeeds, even native admission rejection needs placement rollback.
  if (!targetConnectStarted) {
    return {
      ok: false,
      error,
      profile: input.previousProfile,
      rollback: 'not_started',
      status: input.previousStatus,
    };
  }

  try {
    const previous = await input.resolveProfile(input.previousLocationId, {
      forceRefresh: true,
      requestPermission: false,
    });
    requireCurrentSession(input);
    const rollback = await input.connectProfile(previous);
    requireCurrentSession(input);
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
    requireCurrentSession(input);
    if (rollbackError instanceof SessionOperationSupersededError) throw rollbackError;
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

function requireCurrentSession(input: SwitchVpnLocationInput): void {
  if (input.isCurrentSessionOperation && !input.isCurrentSessionOperation()) {
    throw new SessionOperationSupersededError();
  }
}

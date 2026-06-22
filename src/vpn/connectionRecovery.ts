import type { VpnLocation } from '../api/vexApi';
import type { VpnProfile } from './profile';
import { chooseBestVpnLocation } from './serverSelection';
import type { ConnectedVpnProfile, ResolveConnectableProfileOptions } from './serverSwitch';
import { assessVpnAutopilotIssue } from './vpnAutopilotAssessment';

export type RecoveryOutcome = 'same_profile' | 'same_location_fresh_profile' | 'rotated_profile' | 'failover_location' | 'failed';

export type RecoverVpnConnectionInput = {
  activeLocationId: string;
  activeProfile: VpnProfile;
  availableLocations: VpnLocation[];
  connectProfile: (profile: VpnProfile) => Promise<ConnectedVpnProfile>;
  isRetryableConnectError: (error: unknown) => boolean;
  persistLocation: (locationId: string) => Promise<string>;
  resolveProfile: (locationId: string, options: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
  rotateProfile?: (profile: VpnProfile, locationId: string) => Promise<VpnProfile>;
  setCachedProfile: (locationId: string, profile: VpnProfile) => void;
};

export type RecoverVpnConnectionResult =
  | {
    ok: true;
    locationId: string;
    outcome: Exclude<RecoveryOutcome, 'failed'>;
    previousLocationId: string;
    profile: VpnProfile;
    status: ConnectedVpnProfile['status'];
  }
  | {
    ok: false;
    error: unknown;
    locationId: string;
    outcome: 'failed';
    previousLocationId: string;
    profile: VpnProfile;
    status: null;
  };

export async function recoverVpnConnection(input: RecoverVpnConnectionInput): Promise<RecoverVpnConnectionResult> {
  const activeLocationId = normalizeLocationId(input.activeLocationId || input.activeProfile.locationId);

  try {
    const connected = await input.connectProfile(input.activeProfile);
    return successfulRecovery(input, activeLocationId, connected, 'same_profile');
  } catch (error) {
    if (shouldRotateProfile(input, error)) {
      return recoverWithRotatedProfile(input, activeLocationId, input.activeProfile, error);
    }
    if (!input.isRetryableConnectError(error)) {
      return failedRecovery(input, activeLocationId, error);
    }
    return recoverWithFreshProfile(input, activeLocationId, error);
  }
}

async function recoverWithFreshProfile(
  input: RecoverVpnConnectionInput,
  activeLocationId: string,
  previousError: unknown,
): Promise<RecoverVpnConnectionResult> {
  let freshProfile: VpnProfile | null = null;
  try {
    freshProfile = await input.resolveProfile(activeLocationId, {
      forceRefresh: true,
      requestPermission: false,
    });
    const connected = await input.connectProfile(freshProfile);
    return successfulRecovery(input, activeLocationId, connected, 'same_location_fresh_profile');
  } catch (error) {
    if (freshProfile && shouldRotateProfile(input, error)) {
      return recoverWithRotatedProfile(input, activeLocationId, freshProfile, error);
    }
    if (!input.isRetryableConnectError(error)) {
      return failedRecovery(input, activeLocationId, error);
    }
    return recoverWithFailoverLocation(input, activeLocationId, error ?? previousError);
  }
}

async function recoverWithRotatedProfile(
  input: RecoverVpnConnectionInput,
  activeLocationId: string,
  profile: VpnProfile,
  previousError: unknown,
): Promise<RecoverVpnConnectionResult> {
  if (!input.rotateProfile) {
    return failedRecovery(input, activeLocationId, previousError);
  }
  try {
    const rotatedProfile = await input.rotateProfile(profile, activeLocationId);
    const connected = await input.connectProfile(rotatedProfile);
    return successfulRecovery(input, activeLocationId, connected, 'rotated_profile');
  } catch (error) {
    if (!input.isRetryableConnectError(error)) {
      return failedRecovery(input, activeLocationId, error);
    }
    return recoverWithFailoverLocation(input, activeLocationId, error);
  }
}

async function recoverWithFailoverLocation(
  input: RecoverVpnConnectionInput,
  activeLocationId: string,
  previousError: unknown,
): Promise<RecoverVpnConnectionResult> {
  const failoverLocationId = bestFailoverLocationId(input.availableLocations, activeLocationId);
  if (!failoverLocationId) {
    return failedRecovery(input, activeLocationId, previousError);
  }

  try {
    const failoverProfile = await input.resolveProfile(failoverLocationId, {
      forceRefresh: true,
      requestPermission: false,
    });
    const connected = await input.connectProfile(failoverProfile);
    return successfulRecovery(input, activeLocationId, connected, 'failover_location', failoverLocationId);
  } catch (error) {
    return failedRecovery(input, activeLocationId, error);
  }
}

async function successfulRecovery(
  input: RecoverVpnConnectionInput,
  previousLocationId: string,
  connected: ConnectedVpnProfile,
  outcome: Exclude<RecoveryOutcome, 'failed'>,
  targetLocationId = previousLocationId,
): Promise<RecoverVpnConnectionResult> {
  const locationId = outcome === 'failover_location'
    ? await input.persistLocation(targetLocationId)
    : targetLocationId;
  input.setCachedProfile(locationId, connected.profile);

  return {
    ok: true,
    locationId,
    outcome,
    previousLocationId,
    profile: connected.profile,
    status: connected.status,
  };
}

function failedRecovery(
  input: RecoverVpnConnectionInput,
  previousLocationId: string,
  error: unknown,
): RecoverVpnConnectionResult {
  return {
    ok: false,
    error,
    locationId: previousLocationId,
    outcome: 'failed',
    previousLocationId,
    profile: input.activeProfile,
    status: null,
  };
}

function bestFailoverLocationId(locations: VpnLocation[], activeLocationId: string): string | null {
  const best = chooseBestVpnLocation(
    locations.filter((location) => normalizeLocationId(location.id) !== activeLocationId),
  );
  return best?.id ?? null;
}

function shouldRotateProfile(input: RecoverVpnConnectionInput, error: unknown): boolean {
  return Boolean(input.rotateProfile && assessVpnAutopilotIssue({ error }).cause === 'key_or_profile');
}

function normalizeLocationId(locationId: string): string {
  return locationId.trim().toLowerCase() || 'de';
}

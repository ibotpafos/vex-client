import type { VpnProfile } from './profile';

type EntitlementLike = {
  active?: boolean;
  vpnAccess?: boolean;
};

export function shouldUseLocalProfileBeforeOnline(
  profile: VpnProfile | null | undefined,
  fallbackEntitlement: EntitlementLike | null | undefined,
): profile is VpnProfile {
  if (!profile || profile.rotationRequired) {
    return false;
  }
  return hasPaidEntitlementLike(profile.entitlement ?? fallbackEntitlement);
}

export function vpnConnectTimingSamples(input: {
  endpointAttempts: string[];
  interfaceUpMs: number;
  nativeStartMs: number;
  profile: VpnProfile;
  tapStartedAt: number;
}): Record<string, unknown> {
  return {
    connect_profile_source: input.profile.source,
    endpoint_attempts: input.endpointAttempts,
    hot_profile_age_ms: input.profile.hotProfileAgeMs ?? null,
    hot_profile_used: input.profile.hotProfileUsed === true,
    native_start_to_interface_up_ms: Math.max(0, input.interfaceUpMs - input.nativeStartMs),
    profile_resolve_ms: Math.max(0, input.nativeStartMs - input.tapStartedAt),
    tap_to_native_start_ms: Math.max(0, input.nativeStartMs - input.tapStartedAt),
  };
}

function hasPaidEntitlementLike(item: EntitlementLike | null | undefined): boolean {
  return Boolean(item?.vpnAccess || item?.active);
}

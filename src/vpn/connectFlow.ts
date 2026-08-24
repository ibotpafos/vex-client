import type { VpnProfile } from './profile';
import { vpnProfileAddressMatchesDevice } from './profileConsistency';
import { profileEndpoint } from './connectionFallback';

export const explicitConnectProfileResolutionOptions = {
  forceRefresh: true,
  preferCached: false,
} as const;

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

export function connectableLocalProfile(
  profile: VpnProfile | null | undefined,
  locationId: string,
  fallbackEntitlement: EntitlementLike | null | undefined,
  routingMode?: VpnProfile['routingMode'],
): VpnProfile | null {
  if (!profile || profile.locationId !== locationId) {
    return null;
  }
  if (!vpnProfileAddressMatchesDevice(profile)) {
    return null;
  }
  // A profile without routing metadata is legacy/ambiguous and must not be
  // reused when the caller requested an explicit routing policy.
  if (routingMode && profile.routingMode !== routingMode) {
    return null;
  }
  if (!shouldUseLocalProfileBeforeOnline(profile, fallbackEntitlement)) {
    return null;
  }
  return { ...profile, source: 'local' };
}

export function vpnConnectTimingSamples(input: {
  endpointAttempts: string[];
  interfaceUpMs: number;
  nativeStartMs: number;
  profile: VpnProfile;
  tapStartedAt: number;
  verificationCompletedMs: number;
}): Record<string, unknown> {
  return {
    connect_profile_source: input.profile.source,
    endpoint_attempts: input.endpointAttempts,
    hot_profile_age_ms: input.profile.hotProfileAgeMs ?? null,
    hot_profile_used: input.profile.hotProfileUsed === true,
    native_start_to_interface_up_ms: Math.max(0, input.interfaceUpMs - input.nativeStartMs),
    profile_resolve_ms: Math.max(0, input.nativeStartMs - input.tapStartedAt),
    tap_to_interface_up_ms: Math.max(0, input.interfaceUpMs - input.tapStartedAt),
    tap_to_native_start_ms: Math.max(0, input.nativeStartMs - input.tapStartedAt),
    tap_to_verified_ms: Math.max(0, input.verificationCompletedMs - input.tapStartedAt),
    interface_up_to_verified_ms: Math.max(0, input.verificationCompletedMs - input.interfaceUpMs),
  };
}

export function vpnConnectTelemetry(input: {
  connectedProfile: VpnProfile;
  endpointAttempts: string[];
  initialProfile: VpnProfile;
  locationFallback: boolean;
  tapStartedAt: number;
  verificationCompletedMs: number;
}) {
  const fallbackUsed = input.locationFallback || input.endpointAttempts.length > 1;
  return {
    connectionEvent: fallbackUsed ? 'fallback_succeeded' as const : 'connect_succeeded' as const,
    connectDurationMs: Math.max(0, input.verificationCompletedMs - input.tapStartedAt),
    transportFrom: vpnTransportTelemetry(input.initialProfile),
    transportTo: vpnTransportTelemetry(input.connectedProfile),
  };
}

export function vpnTransportTelemetry(profile: VpnProfile): 'awg3_udp443' | 'awg3' | 'awg2' | 'wireguard' | 'openvpn' | 'unknown' {
  const protocol = profile.device?.protocol?.trim().toLowerCase() ?? '';
  if (protocol.includes('openvpn')) {
    return 'openvpn';
  }
  const hasHeaderProtection = /^HeaderProtectionKey\s*=\s*\S+/m.test(profile.config);
  if (hasHeaderProtection) {
    return endpointPort(profileEndpoint(profile)) === 443 ? 'awg3_udp443' : 'awg3';
  }
  if (protocol.includes('amnezia') || /^Jc\s*=/m.test(profile.config)) {
    return 'awg2';
  }
  if (protocol.includes('wireguard')) {
    return 'wireguard';
  }
  return 'unknown';
}

function endpointPort(endpoint?: string): number | undefined {
  const value = endpoint?.trim() ?? '';
  const match = /:(\d+)$/.exec(value);
  if (!match) {
    return undefined;
  }
  const port = Number(match[1]);
  return Number.isInteger(port) ? port : undefined;
}

function hasPaidEntitlementLike(item: EntitlementLike | null | undefined): boolean {
  return Boolean(item?.vpnAccess || item?.active);
}

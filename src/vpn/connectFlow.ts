import { hasPaidEntitlement, type EntitlementLike } from '../api/entitlement';
import type { VpnProfile } from './profile';
import { vpnProfileAddressMatchesDevice } from './profileConsistency';
import { profileEndpoint } from './connectionFallback';
import { vpnProfileCacheIsCurrent } from './hotProfileCacheCore';

export const explicitConnectProfileResolutionOptions = {
  forceRefresh: false,
  preferCached: true,
  validateCachedProfile: true,
} as const;

// A cached or hot profile is unverified: it may point at an endpoint the server
// already replaced, so it gets a short first probe and a parallel fresh fetch.
export function isUnverifiedProfileSource(profile: Pick<VpnProfile, 'source' | 'hotProfileUsed'>): boolean {
  return profile.source === 'local' || profile.hotProfileUsed === true;
}
export function shouldUseLocalProfileBeforeOnline(
  profile: VpnProfile | null | undefined,
  fallbackEntitlement: EntitlementLike | null | undefined,
  nowMs = Date.now(),
): profile is VpnProfile {
  if (!profile || profile.rotationRequired || !vpnProfileCacheIsCurrent(profile, nowMs)) {
    return false;
  }
  return hasPaidEntitlement(profile.entitlement ?? fallbackEntitlement);
}

export function connectableLocalProfile(
  profile: VpnProfile | null | undefined,
  locationId: string,
  fallbackEntitlement: EntitlementLike | null | undefined,
  routingMode?: VpnProfile['routingMode'],
  nowMs = Date.now(),
): VpnProfile | null {
  if (profile?.transport === 'vless' && (!profile.expiresAt || Date.parse(profile.expiresAt) <= Date.now() || !Number.isFinite(Date.parse(profile.expiresAt)))) return null;
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
  if (!shouldUseLocalProfileBeforeOnline(profile, fallbackEntitlement, nowMs)) {
    return null;
  }
  return { ...profile, cacheSavedAtMs: profile.cacheSavedAtMs === undefined ? nowMs : profile.cacheSavedAtMs, source: 'local' };
}

export function vpnConnectTimingSamples(input: {
  endpointAttempts: string[];
  firstAttemptMs?: number | null;
  interfaceUpMs: number;
  nativeStartMs: number;
  profile: VpnProfile;
  tapStartedAt: number;
  verificationCompletedMs: number;
}): Record<string, unknown> {
  const timing = input.profile.resolutionTiming;
  const preparation = input.profile.connectPreparationTiming;
  const stages: Record<string, number> = {};
  if (input.profile.source === 'api' && timing && timing.startedAtMs >= input.tapStartedAt && timing.startedAtMs <= input.nativeStartMs) {
    if (typeof timing.routingPolicyMs === 'number' && Number.isFinite(timing.routingPolicyMs) && timing.routingPolicyMs >= 0) {
      stages.profile_routing_policy_ms = timing.routingPolicyMs;
    }
    for (const [field, value] of Object.entries({
      profile_local_prepare_ms: timing.localPrepareMs,
      profile_device_lookup_ms: timing.deviceLookupMs,
      profile_request_ms: timing.profileRequestMs,
      profile_queue_wait_ms: timing.queueWaitMs,
    })) {
      if (typeof value === 'number' && Number.isFinite(value) && value >= 0) stages[field] = value;
    }
  }
  if (
    preparation &&
    preparation.startedAtMs >= input.tapStartedAt &&
    preparation.startedAtMs <= input.nativeStartMs &&
    preparation.completedAtMs >= preparation.startedAtMs &&
    preparation.completedAtMs <= input.nativeStartMs
  ) {
    for (const [field, value] of Object.entries({
      profile_entitlement_wait_ms: preparation.entitlementWaitMs,
      profile_hot_cache_lookup_ms: preparation.hotProfileLookupMs,
      profile_key_rotation_ms: preparation.keyRotationMs,
      vpn_permission_wait_ms: preparation.permissionWaitMs,
    })) {
      if (typeof value === 'number' && Number.isFinite(value) && value >= 0) stages[field] = value;
    }
  }
  return {
    ...stages,
    ...(typeof input.firstAttemptMs === 'number' ? { connect_first_attempt_ms: input.firstAttemptMs } : {}),
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

export function vpnUnexpectedDisconnectTelemetry(input: {
  connectedAtMs: number;
  nextState: string;
  nowMs: number;
  profile: VpnProfile;
  previousState: string;
}) {
  if (input.previousState !== 'connected' || (input.nextState !== 'disconnected' && input.nextState !== 'error')) {
    return null;
  }
  return {
    connectionEvent: 'unexpected_disconnect' as const,
    sessionUptimeSeconds: Math.floor(Math.max(0, input.nowMs - input.connectedAtMs) / 1_000),
    transportFrom: vpnTransportTelemetry(input.profile),
  };
}

export function vpnTransportTelemetry(profile: VpnProfile): 'vless' | 'awg3_udp443' | 'awg3' | 'awg2' | 'wireguard' | 'openvpn' | 'unknown' {
  if (profile.transport === 'vless') return 'vless';
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

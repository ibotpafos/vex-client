import type { VpnStatus } from '../native/vexVpn';
import type { NativeTunnelHealthReason } from './nativeTunnelHealth';

export type VpnAutopilotCause =
  | 'dns'
  | 'key_or_profile'
  | 'network'
  | 'permission'
  | 'server'
  | 'subscription'
  | 'unknown';

export type VpnAutopilotProbeResult = {
  dnsOk?: boolean;
  endpointLatencyMs?: number | null;
  endpointProbeError?: string;
  httpsOk?: boolean;
  httpsProbeError?: string;
};

export type VpnAutopilotAssessmentInput = {
  error?: unknown;
  healthReasons?: NativeTunnelHealthReason[];
  localStatus?: VpnStatus;
  probe?: VpnAutopilotProbeResult;
  usageError?: string;
};

export type VpnAutopilotAssessment = {
  cause: VpnAutopilotCause;
  canFailover: boolean;
  diagnosticStatus: string;
  sample: Record<string, unknown>;
  userMessage: string;
};

const slowEndpointLatencyMs = 900;

export function assessVpnAutopilotIssue(input: VpnAutopilotAssessmentInput): VpnAutopilotAssessment {
  const healthReasons = input.healthReasons ?? [];
  const probe = input.probe;
  const messages = [
    normalizedMessage(input.error),
    normalizedMessage(input.usageError),
    normalizedMessage(probe?.endpointProbeError),
    normalizedMessage(probe?.httpsProbeError),
    normalizedMessage(input.localStatus?.verificationReason),
  ].filter(Boolean);
  const joinedMessage = messages.join(' ');
  const cause = classifyVpnAutopilotCause({
    healthReasons,
    joinedMessage,
    probe,
  });

  return {
    cause,
    canFailover: cause === 'server' || cause === 'dns',
    diagnosticStatus: cause,
    sample: {
      autopilot_cause: cause,
      autopilot_can_failover: cause === 'server' || cause === 'dns',
      endpoint_latency_ms: probe?.endpointLatencyMs ?? null,
      endpoint_probe_error: probe?.endpointProbeError,
      health_reasons: healthReasons,
      https_probe_error: probe?.httpsProbeError,
      https_ok: probe?.httpsOk,
      dns_ok: probe?.dnsOk,
      local_status_state: input.localStatus?.state,
      usage_error: input.usageError,
    },
    userMessage: userMessageForCause(cause),
  };
}

function classifyVpnAutopilotCause(input: {
  healthReasons: NativeTunnelHealthReason[];
  joinedMessage: string;
  probe?: VpnAutopilotProbeResult;
}): VpnAutopilotCause {
  const { healthReasons, joinedMessage, probe } = input;

  if (matchesAny(joinedMessage, ['подписка', 'subscription', 'entitlement', 'payment required', 'access inactive'])) {
    return 'subscription';
  }
  if (matchesAny(joinedMessage, ['разрешение', 'permission', 'vpn permission', 'not authorized', 'unauthorized'])) {
    return 'permission';
  }
  if (matchesAny(joinedMessage, ['revoked', 'profile', 'config', 'public key', 'private key', 'wireguard key', 'rotation'])) {
    return 'key_or_profile';
  }
  if (probe?.dnsOk === false || matchesAny(joinedMessage, ['dns', 'resolve', 'lookup', 'name resolution', 'unable to resolve host'])) {
    return 'dns';
  }
  if (probe?.httpsOk === false || matchesAny(joinedMessage, ['network request failed', 'offline', 'no internet', 'timed out', 'timeout', 'cancelled', 'canceled'])) {
    return 'network';
  }
  if (
    healthReasons.includes('device_usage_degraded') ||
    healthReasons.includes('stale_local_handshake') ||
    healthReasons.includes('local_status_error') ||
    matchesAny(joinedMessage, ['handshake', 'endpoint', 'peer', 'stale', 'no_handshake', 'missing_peer']) ||
    (typeof probe?.endpointLatencyMs === 'number' && probe.endpointLatencyMs > slowEndpointLatencyMs)
  ) {
    return 'server';
  }
  if (healthReasons.includes('leak_blocking') || healthReasons.includes('local_status_disconnected')) {
    return 'network';
  }
  return 'unknown';
}

function userMessageForCause(cause: VpnAutopilotCause): string {
  switch (cause) {
    case 'dns':
      return 'Проблема с туннелем: DNS недоступен.';
    case 'key_or_profile':
      return 'Проблема с туннелем: обновляем ключ VPN.';
    case 'network':
      return 'Проблема с туннелем: сеть нестабильна.';
    case 'permission':
      return 'Проблема с туннелем: нужно разрешение VPN.';
    case 'server':
      return 'Проблема с туннелем: сервер нестабилен.';
    case 'subscription':
      return 'Проблема с туннелем: подписка не активна.';
    default:
      return 'Проблема с туннелем. Попробуйте переподключиться позже.';
  }
}

function matchesAny(value: string, needles: string[]): boolean {
  return needles.some((needle) => value.includes(needle));
}

function normalizedMessage(value: unknown): string {
  if (value instanceof Error) {
    return value.message.trim().toLowerCase();
  }
  if (typeof value === 'string') {
    return value.trim().toLowerCase();
  }
  return '';
}

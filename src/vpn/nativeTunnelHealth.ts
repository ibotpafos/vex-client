import type { VpnDeviceUsage } from '../api/vexApi';
import type { VpnStatus } from '../native/vexVpn';

export type NativeTunnelHealthReason =
  | 'vless_data_plane_unverified'
  | 'device_usage_degraded'
  | 'leak_blocking'
  | 'local_status_disconnected'
  | 'local_status_error'
  | 'stale_local_handshake';

export type NativeTunnelHealthInput = {
  transport?: VpnStatus['transport'];
  deviceUsage?: VpnDeviceUsage;
  nowMs: number;
  staleHandshakeSeconds: number;
  status?: VpnStatus;
};

export type NativeTunnelHealthAssessment = {
  healthy: boolean;
  reasons: NativeTunnelHealthReason[];
};

export function assessNativeTunnelHealth(input: NativeTunnelHealthInput): NativeTunnelHealthAssessment {
  const reasons: NativeTunnelHealthReason[] = [];

  if (input.transport === 'vless' && input.status?.transport !== 'vless') reasons.push('vless_data_plane_unverified');
  const handshake = input.status?.latestHandshakeEpochMillis ?? 0;
  const freshLocalHandshake = input.status?.state === 'connected' && handshake > 0 && handshake <= input.nowMs &&
    input.nowMs - handshake <= input.staleHandshakeSeconds * 1000;
  // Server usage is sampled asynchronously. Do not tear down a transport with
  // fresh local handshake evidence because an older usage sample says stale.
  if (input.transport !== 'vless' && input.status?.transport !== 'vless' && !freshLocalHandshake && deviceUsageNeedsReconnect(input.deviceUsage, input.staleHandshakeSeconds)) {
    reasons.push('device_usage_degraded');
  }

  if (input.status) {
    reasons.push(...localStatusHealthReasons(input.status, input.nowMs, input.staleHandshakeSeconds));
  }

  return {
    healthy: reasons.length === 0,
    reasons,
  };
}

export function localStatusHealthReasons(
  status: VpnStatus,
  nowMs: number,
  staleHandshakeSeconds: number,
): NativeTunnelHealthReason[] {
  const reasons: NativeTunnelHealthReason[] = [];
  if (status.leakProtection === 'blocking') {
    reasons.push('leak_blocking');
  }
  if (status.state === 'disconnected') {
    reasons.push('local_status_disconnected');
  } else if (status.state === 'error') {
    reasons.push('local_status_error');
  }
  if (status.transport === 'vless') {
    if (['connected', 'degraded', 'verifying'].includes(status.state) && (status.verified !== true || typeof status.connectionId !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(status.connectionId) ||
        !status.verificationEpochMillis || status.verificationEpochMillis > nowMs ||
        nowMs - status.verificationEpochMillis > staleHandshakeSeconds * 1000)) reasons.push('vless_data_plane_unverified');
    return reasons;
  }
  if (localHandshakeIsStale(status.latestHandshakeEpochMillis, nowMs, staleHandshakeSeconds)) {
    reasons.push('stale_local_handshake');
  }
  return reasons;
}

function deviceUsageNeedsReconnect(usage: VpnDeviceUsage | undefined, staleHandshakeSeconds: number): boolean {
  if (!usage) {
    return false;
  }
  if (typeof usage.secondsSinceHandshake === 'number' && usage.secondsSinceHandshake > staleHandshakeSeconds) {
    return true;
  }
  if (usage.connected) {
    return false;
  }
  return ['stale', 'no_handshake', 'missing_peer', 'never_connected'].includes(usage.connectionStatus);
}

function localHandshakeIsStale(
  latestHandshakeEpochMillis: number | undefined,
  nowMs: number,
  staleHandshakeSeconds: number,
): boolean {
  if (!latestHandshakeEpochMillis || latestHandshakeEpochMillis <= 0) {
    return false;
  }
  return nowMs - latestHandshakeEpochMillis > staleHandshakeSeconds * 1000;
}

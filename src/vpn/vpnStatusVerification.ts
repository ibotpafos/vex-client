import type { VpnStatus } from '@/native/vexVpn';

export function hasVerifiedNativeTunnelActivity(status: VpnStatus, platform: string): boolean {
  const hasHandshake = Boolean(
    status.latestHandshakeEpochMillis && status.latestHandshakeEpochMillis > 0,
  );
  if (platform === 'android' || platform === 'ios') {
    return hasHandshake;
  }
  return hasHandshake || status.rxBytes > 0 || status.txBytes > 0;
}

export function resolveNativeTunnelVerified(status: VpnStatus, platform: string): boolean {
  const hasVerifiedActivity = hasVerifiedNativeTunnelActivity(status, platform);
  if (platform === 'android') {
    // Old Android binaries cannot establish this proof. A signed native update
    // is required; counters and a legacy `verified` flag must fail closed.
    return hasVerifiedActivity && status.verified !== false && status.dataPlaneVerified === true &&
      typeof status.dataPlaneGeneration === 'string' && status.dataPlaneGeneration.length > 0;
  }
  if (platform === 'ios') {
    return hasVerifiedActivity;
  }
  return hasVerifiedActivity || status.verified === true;
}

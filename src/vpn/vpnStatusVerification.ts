import type { VpnStatus } from '@/native/vexVpn';

export function hasVerifiedNativeTunnelActivity(status: VpnStatus, platform: string): boolean {
  const hasHandshake = Boolean(
    status.latestHandshakeEpochMillis && status.latestHandshakeEpochMillis > 0,
  );
  if (platform === 'android') {
    return hasHandshake;
  }
  return hasHandshake || status.rxBytes > 0 || status.txBytes > 0;
}

export function resolveNativeTunnelVerified(status: VpnStatus, platform: string): boolean {
  const hasVerifiedActivity = hasVerifiedNativeTunnelActivity(status, platform);
  if (platform === 'android') {
    return hasVerifiedActivity;
  }
  return hasVerifiedActivity || status.verified === true;
}

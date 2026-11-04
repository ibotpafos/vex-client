import type { VpnStatus } from '@/native/vexVpn';

export function hasVerifiedNativeTunnelActivity(status: VpnStatus, platform: string): boolean {
  if (status.transport === 'vless') {
    return status.state === 'connected' && status.verified === true &&
      typeof status.connectionId === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(status.connectionId) &&
      typeof status.verificationEpochMillis === 'number' && Number.isFinite(status.verificationEpochMillis) && status.verificationEpochMillis > 0;
  }
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
  if (status.transport === 'vless') return hasVerifiedActivity;
  if (platform === 'android' || platform === 'ios') {
    return hasVerifiedActivity;
  }
  return hasVerifiedActivity || status.verified === true;
}

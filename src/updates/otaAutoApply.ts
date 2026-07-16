import type { AppStateStatus } from 'react-native';
import type { VpnStatus } from '@/native/vexVpn';

export function canAutomaticallyApplyOtaUpdate(
  appState: AppStateStatus,
  vpnStatus: Pick<VpnStatus, 'state' | 'leakProtection'>,
): boolean {
  const tunnelIsIdle = vpnStatus.state === 'disconnected' || vpnStatus.state === 'error';
  return appState === 'active' && tunnelIsIdle && vpnStatus.leakProtection !== 'blocking';
}

import { useSyncExternalStore } from 'react';

import type { VpnStatus } from '@/native/vexVpn';

export type VpnTrafficStats = Pick<VpnStatus, 'rxBytes' | 'txBytes'>;

const defaultTrafficStats: VpnTrafficStats = {
  rxBytes: 0,
  txBytes: 0,
};

let trafficStatsSnapshot: VpnTrafficStats = defaultTrafficStats;
const listeners = new Set<() => void>();

export function readVpnTrafficStatsSnapshot(): VpnTrafficStats {
  return trafficStatsSnapshot;
}

export function publishVpnTrafficStats(nextStatus: VpnStatus | VpnTrafficStats): void {
  const nextSnapshot: VpnTrafficStats = {
    rxBytes: nextStatus.rxBytes,
    txBytes: nextStatus.txBytes,
  };
  if (
    trafficStatsSnapshot.rxBytes === nextSnapshot.rxBytes &&
    trafficStatsSnapshot.txBytes === nextSnapshot.txBytes
  ) {
    return;
  }
  trafficStatsSnapshot = nextSnapshot;
  listeners.forEach((listener) => listener());
}

export function resetVpnTrafficStats(): void {
  publishVpnTrafficStats(defaultTrafficStats);
}

export function useVpnTrafficStats(): VpnTrafficStats {
  return useSyncExternalStore(subscribe, readVpnTrafficStatsSnapshot, readVpnTrafficStatsSnapshot);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

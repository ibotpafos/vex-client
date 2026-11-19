import { requireRequestActive } from '../api/error';
import type { PreparedTunnelOptions, VpnDevice } from '../api/types';

export class SessionOperationSupersededError extends Error {
  readonly code = 'SESSION_OPERATION_SUPERSEDED';

  constructor() {
    super('VPN operation was superseded.');
    this.name = 'SessionOperationSupersededError';
  }
}

export function requireCurrentSession(isCurrentSessionOperation?: () => boolean): void {
  if (isCurrentSessionOperation && !isCurrentSessionOperation()) {
    throw new SessionOperationSupersededError();
  }
}

export function requireProfileRequest(options: PreparedTunnelOptions): void {
  requireCurrentSession(options.isCurrentSessionOperation);
  requireRequestActive(options.signal);
}

export function isManagedClientOwnedDevice(device: VpnDevice): boolean {
  return device.provisioningMode === 'managed_native' || device.clientKeyOwnership === 'client';
}

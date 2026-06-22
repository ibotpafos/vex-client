import { Platform } from 'react-native';
import { hasPaidEntitlement, type Entitlement, type VpnLocation } from '@/api/vexApi';
import type { VpnStatus } from '@/native/vexVpn';
import type { VpnProfile } from '@/vpn/profile';
import type { ServerSelectionMode } from '@/vpn/serverSelection';

export const animationKickDelayMs = 80;
export const activeDeviceRefreshMs = 15_000;
export const nativeStatusPollMs = 2_500;
export const nativeHealthPollMs = 30_000;
export const nativeHealthFailureThreshold = 2;
export const nativeReconnectCooldownMs = 120_000;
export const staleHandshakeReconnectSeconds = 180;
export const clientDiagnosticsHeartbeatMs = 5 * 60_000;
export const clientDiagnosticsErrorCooldownMs = 60_000;
export const prewarmedProfileStaleMs = 2 * 60_000;
export const connectAttemptTimeoutMs = 25_000;

export const vpnStatusChangedEvent = 'vpn-status-changed';
export const vpnProfileChangedEvent = 'vpn-profile-changed';

export type DiagnosticsSnapshotRef = {
  vpnStatus: VpnStatus;
  latencyMs: number | null;
  endpoint?: string;
  profileVersion?: number;
  routingMode?: string;
  bypassRegion?: string;
  bypassRangesCount?: number;
  routingPolicyVersion?: string;
  selectedLocationId?: string;
};

export type ConnectedVpnAttempt = {
  endpointAttempts: string[];
  interfaceUpMs: number;
  nativeStartMs: number;
  profile: VpnProfile;
  status: VpnStatus;
};

export type ConnectionPhase = 'idle' | 'connecting' | 'connected' | 'verifying' | 'degraded' | 'disconnecting' | 'switching' | 'blocked';

export function isTauriRuntime() {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

export function supportsNativeLatencyProbe() {
  return isTauriRuntime() || Platform.OS === 'android';
}

export function supportsNativeVpnWatchdog() {
  return isTauriRuntime() || Platform.OS === 'android';
}

export function supportsNativeStatusPolling() {
  return isTauriRuntime() || Platform.OS === 'android' || Platform.OS === 'ios';
}

export function nextVpnStatusWithState(current: VpnStatus, state: VpnStatus['state']): VpnStatus {
  return { ...current, state };
}

export function areVpnStatusesEqual(left: VpnStatus, right: VpnStatus) {
  return left.state === right.state && left.rxBytes === right.rxBytes && left.txBytes === right.txBytes;
}

export function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && typeof error.message === 'string' && error.message.trim()) {
    return error.message;
  }
  if (typeof error === 'string' && error.trim()) {
    return error;
  }
  return fallback;
}

export function timeoutError(message: string): Error {
  const error = new Error(message);
  error.name = 'TimeoutError';
  return error;
}

export function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(timeoutError(message)), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

export function isAuthenticationError(message: string): boolean {
  return message.includes('401') || message.includes('Unauthorized') || message.includes('authentication required');
}

export function waitForAnimationKick() {
  return new Promise<void>((resolve) => {
    if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(() => {
        window.setTimeout(resolve, animationKickDelayMs);
      });
      return;
    }
    setTimeout(resolve, animationKickDelayMs);
  });
}

export function disconnectedVpnStatus(): VpnStatus {
  return {
    state: 'disconnected',
    rxBytes: 0,
    txBytes: 0,
    leakProtection: 'off',
  };
}

export function deviceLatencyText(latencyMs?: number | null) {
  if (typeof latencyMs === 'number' && Number.isFinite(latencyMs)) {
    return `${Math.max(0, Math.round(latencyMs))} мс`;
  }
  return '-- мс';
}

export function locationLatencyText(location: VpnLocation | undefined, liveLatencyMs?: number | null) {
  if (typeof liveLatencyMs === 'number' && Number.isFinite(liveLatencyMs)) {
    return deviceLatencyText(liveLatencyMs);
  }
  return deviceLatencyText(location?.latencyMs);
}

export function availableVpnLocations(locations?: VpnLocation[]): VpnLocation[] {
  const source = locations?.length ? locations : fallbackVpnLocations;
  return source.filter((location) => location.availability !== 'retired');
}

export function serverLocationLabel(location: VpnLocation): string {
  return `${location.flagEmoji ? `${location.flagEmoji} ` : ''}${location.city}`;
}

export function locationStatusText(location: VpnLocation): string {
  if (location.status === 'healthy' && location.healthyNodes > 0) {
    return 'Доступен';
  }
  if (location.healthyNodes > 0) {
    return 'Доступен';
  }
  return 'Недоступен';
}

export function formatBytes(value: number) {
  const safeValue = Math.max(0, value);
  if (safeValue < 1024) return `${safeValue} Б`;
  const kb = safeValue / 1024;
  if (kb < 1024) return `${kb.toFixed(kb >= 100 ? 0 : 1)} КБ`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(mb >= 100 ? 0 : 1)} МБ`;
  return `${(mb / 1024).toFixed(1)} ГБ`;
}

export const fallbackVpnLocations: VpnLocation[] = [
  {
    id: 'de',
    countryCode: 'DE',
    city: 'Germany',
    flagEmoji: '🇩🇪',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
  {
    id: 'fi',
    countryCode: 'FI',
    city: 'Finland',
    flagEmoji: '🇫🇮',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
];

export function subscriptionTierLabel(entitlementState: Entitlement | null): string | null {
  if (!hasPaidEntitlement(entitlementState)) {
    return null;
  }

  return planChipLabel(
    entitlementState.tier,
    entitlementState.planId,
    entitlementState.subscriptionTitle,
    entitlementState.displayName,
  );
}

export function planChipLabel(...values: Array<string | undefined>): string {
  for (const value of values) {
    const normalized = normalizePlanLabel(value);
    if (normalized) {
      return normalized;
    }
  }
  return 'Active';
}

export function normalizePlanLabel(value?: string): string | null {
  const raw = value?.trim();
  if (!raw) {
    return null;
  }

  const lower = raw.toLowerCase();
  if (lower.includes('team')) return 'Team';
  if (lower.includes('pro')) return 'Pro';
  if (lower.includes('basic')) return 'Basic';

  const firstToken = raw
    .replace(/аккаунт/gi, '')
    .replace(/подписка/gi, '')
    .replace(/[_-]+/g, ' ')
    .trim()
    .split(/\s+/)[0];
  if (!firstToken) {
    return null;
  }
  return firstToken.charAt(0).toUpperCase() + firstToken.slice(1);
}

export function subscriptionSummaryText(entitlementState: Entitlement | null) {
  if (!entitlementState) return 'Управление доступом';
  if (entitlementState.active) return 'Доступ активен';
  return entitlementState.subscriptionSubtitle || entitlementState.accountStatus || 'Управление доступом';
}

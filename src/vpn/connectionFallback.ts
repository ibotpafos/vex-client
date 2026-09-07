import type { VpnProfile } from './profile';

const awg3HeaderProtectionPattern = /^HeaderProtectionKey\s*=\s*\S+/m;

export class AWG3RecoveryPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AWG3RecoveryPolicyError';
  }
}

export function isAWG3Profile(profile: VpnProfile): boolean {
  return awg3HeaderProtectionPattern.test(profile.config);
}

export function isVpnTransportFallbackError(error: unknown): boolean {
  if (isVpnAdmissionError(error)) return false;
  if (error instanceof AWG3RecoveryPolicyError) {
    return true;
  }
  const message = errorText(error).toLowerCase();
  return message.includes('handshake') ||
    message.includes('vpn connection failed') ||
    message.includes('vpn_connect_failed') ||
    message.includes('network') ||
    message.includes('timeout') ||
    message.includes('timed out');
}

export function connectionAttemptsForProfile(profile: VpnProfile): VpnProfile[] {
  if (!isAWG3Profile(profile)) {
    throw new AWG3RecoveryPolicyError('VPN recovery requires an AWG3 profile with HeaderProtectionKey.');
  }
  if (!profileEndpoint(profile)) {
    throw new AWG3RecoveryPolicyError('VPN recovery requires a signed AWG3 endpoint.');
  }
  // The current contract supplies one endpoint. A cache is not authorization.
  return [profile];
}

/** Production native-attempt boundary; admission errors retain the existing tunnel. */
export async function connectSuppliedProfile<T>(profile: VpnProfile, connect: (attempt: VpnProfile) => Promise<T>): Promise<T> {
  let lastError: unknown;
  for (const attempt of connectionAttemptsForProfile(profile)) {
    try { return await connect(attempt); }
    catch (error) {
      if (!isVpnTransportFallbackError(error)) throw error;
      lastError = error;
    }
  }
  throw lastError;
}

export function isVpnAdmissionError(error: unknown): boolean {
  return typeof error === 'object' && error !== null &&
    'code' in error && error.code === 'VPN_CONFIG_INVALID';
}

export function profileEndpoint(profile: VpnProfile): string | undefined {
  return profile.device?.endpoint || configEndpoint(profile.config);
}

function configEndpoint(config: string): string | undefined {
  return /^Endpoint\s*=\s*(.+)$/m.exec(config)?.[1]?.trim();
}

function errorText(error: unknown): string {
  if (error instanceof Error && typeof error.message === 'string') {
    return error.message.trim();
  }
  return typeof error === 'string' ? error.trim() : '';
}

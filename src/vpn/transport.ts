import { isVpnTransportFallbackError } from './connectionFallback';

export type VpnTransport = 'amneziawg' | 'vless';
export type VpnTransportPreference = VpnTransport | 'auto';

export function normalizeVpnTransportPreference(value: unknown): VpnTransportPreference {
  return value === 'amneziawg' || value === 'vless' ? value : 'auto';
}

export function canFallbackVpnProtocol(error: unknown, phase: 'profile' | 'native'): boolean {
  const coded = error as { code?: unknown; status?: unknown } | null;
  // Only a non-creating capability refusal is definitive; 503 can follow token issuance.
  if (coded?.code === 'protocol_not_supported' && (coded.status === 404 || coded.status === 501)) return true;
  // An unknown issuance result, authorization/key error or live native timeout is terminal.
  if (phase !== 'native' || (coded?.code && coded.code !== 'VPN_CONNECT_FAILED') || coded?.status) return false;
  return isVpnTransportFallbackError(error);
}

export function normalizeVpnTransport(value: unknown): VpnTransport {
  return value === 'vless' ? 'vless' : 'amneziawg';
}

// Keep legacy AWG cache keys intact; VLESS credentials have a separate scope.
export function vpnProfileQueryKey(token: string | undefined, locationId: string, routingMode: string, transport: VpnTransport = 'amneziawg') {
  return transport === 'vless'
    ? ['vpn-profile', token, locationId, routingMode, 'vless'] as const
    : ['vpn-profile', token, locationId, routingMode] as const;
}

export function availableVpnTransportPreference(preference: VpnTransportPreference, supportsVless: boolean): VpnTransportPreference {
  return preference === 'vless' && !supportsVless ? 'auto' : preference;
}

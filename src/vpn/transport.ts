export type VpnTransport = 'amneziawg' | 'vless';

export function normalizeVpnTransport(value: unknown): VpnTransport {
  return value === 'vless' ? 'vless' : 'amneziawg';
}

// Keep legacy AWG cache keys intact; VLESS credentials have a separate scope.
export function vpnProfileQueryKey(token: string | undefined, locationId: string, routingMode: string, transport: VpnTransport = 'amneziawg') {
  return transport === 'vless'
    ? ['vpn-profile', token, locationId, routingMode, 'vless'] as const
    : ['vpn-profile', token, locationId, routingMode] as const;
}

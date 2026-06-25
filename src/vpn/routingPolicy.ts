export type VpnRoutingMode = 'all_except_ru' | 'full_tunnel';

export const defaultVpnRoutingMode: VpnRoutingMode = 'all_except_ru';
export const defaultVpnBypassRegion = 'ru';
export const defaultVpnRoutingPolicyVersion = '2026.06.22.1';

export function normalizeVpnRoutingMode(value: string | null | undefined): VpnRoutingMode {
  return value === 'full_tunnel' ? 'full_tunnel' : 'all_except_ru';
}

export function vpnRoutingModeFromSmartMode(enabled: boolean): VpnRoutingMode {
  return enabled ? 'all_except_ru' : 'full_tunnel';
}

export function isSmartRoutingMode(mode: VpnRoutingMode | string | null | undefined): boolean {
  return normalizeVpnRoutingMode(mode) === 'all_except_ru';
}

export function resolvedVpnBypassRegion(mode: VpnRoutingMode = defaultVpnRoutingMode, bypassRegion = defaultVpnBypassRegion): string | undefined {
  if (mode === 'full_tunnel') {
    return undefined;
  }
  return bypassRegion.trim().toLowerCase() || defaultVpnBypassRegion;
}

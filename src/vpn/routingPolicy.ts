export type VpnRoutingMode = 'all_except_ru' | 'full_tunnel';

export const defaultVpnRoutingMode: VpnRoutingMode = 'all_except_ru';
export const defaultVpnBypassRegion = 'ru';
export const defaultVpnRoutingPolicyVersion = '2026.06.22.1';

export function resolvedVpnBypassRegion(mode: VpnRoutingMode = defaultVpnRoutingMode, bypassRegion = defaultVpnBypassRegion): string | undefined {
  if (mode === 'full_tunnel') {
    return undefined;
  }
  return bypassRegion.trim().toLowerCase() || defaultVpnBypassRegion;
}

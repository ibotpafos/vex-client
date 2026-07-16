import type { VpnProfile } from './profile';

export function vpnProfileAddressMatchesDevice(profile: VpnProfile): boolean {
  const assignedIpv4 = normalizeIpv4(profile.device?.assignedIpv4);
  const interfaceIpv4 = vpnProfileInterfaceIpv4(profile.config);
  return !assignedIpv4 || !interfaceIpv4 || assignedIpv4 === interfaceIpv4;
}

export function vpnProfileInterfaceIpv4(config: string): string | undefined {
  const addressLine = /^Address\s*=\s*(.+)$/im.exec(config)?.[1];
  if (!addressLine) {
    return undefined;
  }
  for (const value of addressLine.split(',')) {
    const address = normalizeIpv4(value.split('/')[0]);
    if (address) {
      return address;
    }
  }
  return undefined;
}

function normalizeIpv4(value?: string): string | undefined {
  const candidate = value?.trim();
  return candidate && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(candidate) ? candidate : undefined;
}

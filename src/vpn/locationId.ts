export function requireVpnLocationId(locationId?: string | null): string {
  const value = locationId?.trim();
  if (!value) {
    throw new Error('VPN location ID is required.');
  }
  return value;
}

export function comparableVpnLocationId(locationId?: string | null): string {
  return locationId?.trim().toLowerCase() ?? '';
}

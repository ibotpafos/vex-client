export function fallbackLocationEndpoint(locationId: string) {
  const normalized = locationId.trim().toLowerCase();
  return /^[a-z]{2}$/.test(normalized) ? `${normalized}-1.vexguard.app:51820` : '';
}

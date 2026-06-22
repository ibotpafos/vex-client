export type VpnLocationDevice = {
  endpoint?: string;
  externalDeviceId?: string;
  nodeId?: string;
};

export function isVpnDeviceForLocation(device: VpnLocationDevice, locationId: string): boolean {
  const normalizedLocationId = normalizeLocationId(locationId);
  if (device.externalDeviceId?.endsWith(`:${normalizedLocationId}`)) {
    return true;
  }
  if (device.nodeId?.toLowerCase().startsWith(`${normalizedLocationId}-`)) {
    return true;
  }
  if (device.nodeId) {
    return false;
  }
  const endpointHost = device.endpoint?.toLowerCase().split(':', 1)[0] || '';
  return endpointHost === normalizedLocationId || endpointHost.startsWith(`${normalizedLocationId}-`);
}

function normalizeLocationId(locationId: string): string {
  return locationId.trim().toLowerCase() || "de";
}

import { isVpnDeviceForLocation } from './deviceLocation';

const mobileProtocol = 'amneziawg';

export type NativeVpnDevice = {
  endpoint?: string;
  externalDeviceId?: string;
  nodeId?: string;
  protocol?: string;
  status: string;
};

export function nativeVpnDeviceForClient<T extends NativeVpnDevice>(
  devices: T[],
  locationId: string,
  externalDeviceId: string,
  baseExternalDeviceId: string,
): T | undefined {
  const exactDevice = activeNativeDeviceByExternalId(devices, externalDeviceId);
  if (exactDevice) {
    return exactDevice;
  }

  const legacyLocationDevice = activeNativeDeviceByExternalId(devices, nativeDeviceLocationId(baseExternalDeviceId, locationId));
  if (legacyLocationDevice) {
    return legacyLocationDevice;
  }

  const globalDevice = activeNativeDeviceByExternalId(devices, baseExternalDeviceId);
  if (globalDevice && isVpnDeviceForLocation(globalDevice, locationId)) {
    return globalDevice;
  }

  return undefined;
}

function activeNativeDeviceByExternalId<T extends NativeVpnDevice>(devices: T[], externalDeviceId: string): T | undefined {
  return devices.find((device) => {
    return isActiveNativeVpnDevice(device) && device.externalDeviceId === externalDeviceId;
  });
}

function isActiveNativeVpnDevice(device: NativeVpnDevice): boolean {
  return isActiveMobileProtocolDevice(device) &&
    Boolean(device.externalDeviceId);
}

function isActiveMobileProtocolDevice(device: NativeVpnDevice): boolean {
  return device.status === 'active' && device.protocol === mobileProtocol;
}

function nativeDeviceLocationId(deviceId: string, locationId: string): string {
  return `${deviceId.trim()}:${normalizeLocationId(locationId)}`;
}

function normalizeLocationId(locationId?: string): string {
  return locationId?.trim().toLowerCase() || 'de';
}

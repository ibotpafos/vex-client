export type DeviceCreatePlatform = 'android' | 'ios' | 'windows' | 'macos' | 'linux' | 'web';

export type DeviceCreateClientDescriptor = {
  deviceName: string;
  idempotencyPrefix: string;
  platform: DeviceCreatePlatform;
};

export type DeviceCreateAppInfo = {
  platform: DeviceCreatePlatform;
  version: string;
};

const mobileProtocol = 'amneziawg';

export function buildCreateDeviceRequest(
  client: DeviceCreateClientDescriptor,
  location: string | undefined,
  externalDeviceId: string,
  appInfo: DeviceCreateAppInfo,
): {
  idempotencyKey: string;
  body: {
    name: string;
    location: string;
    protocol: string;
    external_device_id: string;
    platform: DeviceCreatePlatform;
    app_version: string;
  };
} {
  const normalizedLocation = normalizeLocationId(location);
  const normalizedExternalDeviceId = externalDeviceId.trim();
  return {
    idempotencyKey: `${client.idempotencyPrefix}-${normalizedExternalDeviceId}-${normalizedLocation}-device`,
    body: {
      name: client.deviceName,
      location: normalizedLocation,
      protocol: mobileProtocol,
      external_device_id: normalizedExternalDeviceId,
      platform: client.platform || appInfo.platform,
      app_version: appInfo.version,
    },
  };
}

function normalizeLocationId(locationId?: string): string {
  return locationId?.trim().toLowerCase() || 'de';
}

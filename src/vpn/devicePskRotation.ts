import type { VpnProfile } from './profile';

export type DevicePSKRotationEvent = {
  eventId: string;
  type: 'profile_updated' | 'cutover_ready';
  deviceId: string;
  rotationId: string;
  profileVersion: number;
};

export type StagedDevicePSKProfile = {
  rotationId: string;
  deviceId: string;
  profileVersion: number;
  profileDigest: string;
  profile: VpnProfile;
};

export type DevicePSKRotationDependencies = {
  acknowledge: (staged: StagedDevicePSKProfile) => Promise<void>;
  activate: (staged: StagedDevicePSKProfile) => Promise<void>;
  clear: () => Promise<void>;
  fetch: (event: DevicePSKRotationEvent) => Promise<StagedDevicePSKProfile>;
  load: () => Promise<StagedDevicePSKProfile | null>;
  save: (staged: StagedDevicePSKProfile) => Promise<void>;
};

export type DevicePSKRotationResult = 'ignored' | 'staged' | 'activated';

export async function processDevicePSKRotationEvent(
  event: DevicePSKRotationEvent,
  activeDeviceId: string,
  dependencies: DevicePSKRotationDependencies,
): Promise<DevicePSKRotationResult> {
  if (!eventMatchesDevice(event, activeDeviceId)) {
    return 'ignored';
  }

  if (event.type === 'profile_updated') {
    const persisted = await dependencies.load();
    const staged = persisted && stagedProfileMatchesEvent(event, persisted)
      ? persisted
      : await dependencies.fetch(event);
    requireMatchingStagedProfile(event, staged);
    // The ACK means "durably staged". Keep this ordering explicit.
    await dependencies.save(staged);
    await dependencies.acknowledge(staged);
    return 'staged';
  }

  const staged = await dependencies.load();
  if (!staged || !stagedProfileMatchesEvent(event, staged)) {
    return 'ignored';
  }
  await dependencies.activate(staged);
  await dependencies.clear();
  return 'activated';
}

export function parseDevicePSKRotationEvent(input: Record<string, unknown>): DevicePSKRotationEvent | null {
  const type = stringField(input, 'type');
  if (type !== 'profile_updated' && type !== 'cutover_ready') {
    return null;
  }
  const event: DevicePSKRotationEvent = {
    eventId: stringField(input, 'event_id'),
    type,
    deviceId: stringField(input, 'device_id'),
    rotationId: stringField(input, 'rotation_id'),
    profileVersion: integerField(input, 'profile_version'),
  };
  return event.eventId && event.deviceId && event.rotationId && event.profileVersion > 0 ? event : null;
}

function eventMatchesDevice(event: DevicePSKRotationEvent, activeDeviceId: string): boolean {
  return Boolean(activeDeviceId.trim()) && event.deviceId === activeDeviceId.trim();
}

function requireMatchingStagedProfile(event: DevicePSKRotationEvent, staged: StagedDevicePSKProfile): void {
  if (!stagedProfileMatchesEvent(event, staged) || !staged.profileDigest.trim()) {
    throw new Error('Сервер вернул несовпадающий staged AmneziaWG профиль.');
  }
}

function stagedProfileMatchesEvent(event: DevicePSKRotationEvent, staged: StagedDevicePSKProfile): boolean {
  return staged.deviceId === event.deviceId
    && staged.rotationId === event.rotationId
    && staged.profileVersion === event.profileVersion
    && staged.profile.profileVersion === event.profileVersion;
}

function stringField(input: Record<string, unknown>, key: string): string {
  const value = input[key];
  return typeof value === 'string' ? value.trim() : '';
}

function integerField(input: Record<string, unknown>, key: string): number {
  const value = input[key];
  const parsed = typeof value === 'number' ? value : Number.parseInt(String(value ?? ''), 10);
  return Number.isInteger(parsed) ? parsed : 0;
}

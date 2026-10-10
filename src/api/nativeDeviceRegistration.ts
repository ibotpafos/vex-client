export type NativeDeviceRegistrationAttempt<T> = {
  accessToken: string;
  externalDeviceId: string;
  promise: Promise<T>;
};

const registrationAttempts = new Map<string, Map<string, Promise<unknown>>>();

export function getOrCreateNativeDeviceRegistration<T>(
  accessToken: string,
  externalDeviceId: string,
  start: () => Promise<T>,
): Promise<T> {
  let devices = registrationAttempts.get(accessToken);
  const existing = devices?.get(externalDeviceId);
  if (existing) return existing as Promise<T>;
  if (!devices) {
    devices = new Map();
    registrationAttempts.set(accessToken, devices);
  }
  // Coalesce only requests in flight. A completed result cannot override a
  // later authoritative device lookup after deletion or binding replacement.
  const promise = Promise.resolve().then(start);
  devices.set(externalDeviceId, promise);
  const pendingDevices = devices;
  const release = () => {
    if (pendingDevices.get(externalDeviceId) === promise) {
      pendingDevices.delete(externalDeviceId);
      if (pendingDevices.size === 0) registrationAttempts.delete(accessToken);
    }
  };
  void promise.then(release, release);
  return promise;
}

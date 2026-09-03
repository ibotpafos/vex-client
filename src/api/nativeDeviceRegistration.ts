export type NativeDeviceRegistrationAttempt<T> = {
  accessToken: string;
  externalDeviceId: string;
  promise: Promise<T>;
};

let sharedRegistrationAttempt: NativeDeviceRegistrationAttempt<unknown> | null = null;

export function getOrCreateNativeDeviceRegistration<T>(
  accessToken: string,
  externalDeviceId: string,
  start: () => Promise<T>,
): Promise<T> {
  if (
    sharedRegistrationAttempt?.accessToken === accessToken &&
    sharedRegistrationAttempt.externalDeviceId === externalDeviceId
  ) {
    return sharedRegistrationAttempt.promise as Promise<T>;
  }

  const attempt: NativeDeviceRegistrationAttempt<T> = {
    accessToken,
    externalDeviceId,
    promise: start(),
  };
  sharedRegistrationAttempt = attempt as NativeDeviceRegistrationAttempt<unknown>;
  const clearCompletedAttempt = () => {
    if (sharedRegistrationAttempt === attempt) {
      sharedRegistrationAttempt = null;
    }
  };
  void attempt.promise.then(clearCompletedAttempt, clearCompletedAttempt);
  return attempt.promise;
}

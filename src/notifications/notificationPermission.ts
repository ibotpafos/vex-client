type PermissionState = { granted: boolean; status: string; canAskAgain: boolean };
type PermissionDependencies = {
  get: () => Promise<PermissionState>;
  request: () => Promise<{ granted: boolean }>;
};

/** One automatic OS prompt per process; every check still reads settings fresh. */
export function createNotificationPermissionGate(deps: PermissionDependencies) {
  let attempted = false;
  let inFlight: Promise<boolean> | undefined;
  return async (allowPrompt: boolean): Promise<boolean> => {
    const current = await deps.get();
    if (current.granted) return true;
    // canAskAgain alone is not consent: Android can report it after a denial.
    if (!allowPrompt || !current.canAskAgain || current.status !== 'undetermined') return false;
    if (attempted) return inFlight ?? false;
    // Set synchronously before entering the OS request: foreground/profile
    // effects can restart while the permission dialog is still displayed.
    attempted = true;
    inFlight = Promise.resolve().then(() => deps.request()).then(result => result.granted).finally(() => {
      inFlight = undefined;
    });
    return inFlight;
  };
}
